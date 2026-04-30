"""HDLFACTORY API.

Responsibilities:
- Accept prompt + benchmark uploads.
- Enqueue generation work for the worker via Redis.
- Persist and expose job lifecycle state via SQLite.
- Serve generated artifacts and execution logs.
"""

import json
import shutil
import sqlite3
import uuid
from datetime import datetime
from pathlib import Path
import subprocess
import os
import glob

import redis
import requests
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse

app = FastAPI()

# Open CORS simplifies local frontend integration while API is containerized.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

MODEL = "mistral:7b"

# All runtime artifacts are stored relative to the backend container working dir.
BASE_DIR = Path(__file__).resolve().parent
JOBS_DIR = BASE_DIR / "jobs"
DATA_DIR = BASE_DIR / "data"
DB_PATH = DATA_DIR / "jobs.db"

# Ensure bind-mounted folders exist before first request is handled.
JOBS_DIR.mkdir(exist_ok=True)
DATA_DIR.mkdir(exist_ok=True)

# Redis list `hdl_jobs` acts as the producer/consumer queue.
redis_client = redis.Redis(host="redis", port=6379, decode_responses=True)


def init_db() -> None:
    """Create required SQLite schema if it does not already exist."""
    # Keep DB access short-lived per call; SQLite handles local file locking.
    conn = sqlite3.connect(DB_PATH)
    # Create the baseline jobs table for fresh deployments.
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY,
            prompt TEXT,
            success INTEGER,
            summary TEXT,
            status TEXT,
            created_at TEXT,
            is_deleted INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    # Apply lightweight migration so older DB files still work.
    columns = {row[1] for row in conn.execute("PRAGMA table_info(jobs)")}
    if "is_deleted" not in columns:
        conn.execute("ALTER TABLE jobs ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0")
    conn.commit()
    conn.close()


def update_job(job_id: str, **fields) -> None:
    """Insert or patch a job row.

    Args:
        job_id: Stable UUID for the job.
        **fields: Mutable columns to write (prompt, success, summary, status,
            created_at).
    """
    # Update pattern is intentionally idempotent so worker/API can call safely.
    conn = sqlite3.connect(DB_PATH)
    existing = conn.execute(
        "SELECT job_id, is_deleted FROM jobs WHERE job_id = ?",
        (job_id,),
    ).fetchone()

    if existing and existing[1] == 1:
        conn.close()
        return

    if not existing:
        # First write for a job creates the canonical row.
        conn.execute(
            """
            INSERT INTO jobs (job_id, prompt, success, summary, status, created_at, is_deleted)
            VALUES (?, ?, ?, ?, ?, ?, 0)
            """,
            (
                job_id,
                fields.get("prompt", ""),
                fields.get("success"),
                fields.get("summary", ""),
                fields.get("status", "queued"),
                fields.get(
                    "created_at",
                    datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                ),
            ),
        )
    else:
        allowed = {"prompt", "success", "summary", "status", "created_at"}
        # Patch only known columns to avoid accidental schema drift.
        for key, value in fields.items():
            if key in allowed:
                # Column names come from a local allowlist to avoid SQL injection.
                conn.execute(
                    f"UPDATE jobs SET {key} = ? WHERE job_id = ?",
                    (value, job_id),
                )

    conn.commit()
    conn.close()


def delete_job(job_id: str) -> bool:
    """Mark a job as deleted and remove its on-disk artifacts."""
    conn = sqlite3.connect(DB_PATH)
    # Guard against deleting rows already hidden from history.
    row = conn.execute(
        "SELECT job_id FROM jobs WHERE job_id = ? AND is_deleted = 0",
        (job_id,),
    ).fetchone()

    if not row:
        conn.close()
        return False

    # Soft-delete preserves historical records while hiding them from the API.
    conn.execute(
        "UPDATE jobs SET is_deleted = 1 WHERE job_id = ?",
        (job_id,),
    )
    conn.commit()
    conn.close()

    shutil.rmtree(JOBS_DIR / job_id, ignore_errors=True)
    return True


def read_logs(job_id: str) -> tuple[str, str]:
    """Load job logs from disk.

    Returns:
        Tuple of (stdout, stderr). Missing files are represented as empty strings.
    """
    job_dir = JOBS_DIR / job_id
    stdout_path = job_dir / "stdout.log"
    stderr_path = job_dir / "stderr.log"

    # Missing log files are normal for queued/in-progress jobs.
    stdout = stdout_path.read_text(encoding="utf-8") if stdout_path.exists() else ""
    stderr = stderr_path.read_text(encoding="utf-8") if stderr_path.exists() else ""
    return stdout, stderr


init_db()


@app.post("/generate")
async def generate(
    prompt: str = Form(...),
    benchmark_file: UploadFile = File(...),
):
    """Create a queued job from user input.

    Flow:
    1) Persist prompt + benchmark in a per-job folder.
    2) Insert initial queued status in SQLite.
    3) Push job metadata into Redis for async processing.
    """
    # Generate opaque job identifier returned to client for polling.
    job_id = str(uuid.uuid4())
    job_dir = JOBS_DIR / job_id
    job_dir.mkdir(parents=True, exist_ok=True)

    # Worker reads these files from the shared jobs volume.
    prompt_path = job_dir / "prompt.txt"
    benchmark_path = job_dir / "benchmark_tb.v"

    try:
        # Persist original request inputs for reproducibility/debugging.
        prompt_path.write_text(prompt, encoding="utf-8")

        with benchmark_path.open("wb") as f:
            shutil.copyfileobj(benchmark_file.file, f)

        update_job(
            job_id,
            prompt=prompt,
            success=None,
            summary="Job queued.",
            status="queued",
            created_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        )

        # Push job metadata into Redis for asynchronous worker processing.
        redis_client.rpush(
            "hdl_jobs",
            json.dumps({"job_id": job_id, "prompt": prompt}),
        )

        # Frontend starts polling immediately using returned job metadata.
        return JSONResponse(
            content={
                "job_id": job_id,
                "success": None,
                "summary": "Job queued.",
                "status": "queued",
            }
        )

    except Exception as e:
        # Errors here happen before worker picks up the job.
        return JSONResponse(
            status_code=500,
            content={
                "job_id": job_id,
                "success": False,
                "summary": f"Server error: {str(e)}",
                "status": "failed",
            },
        )


@app.get("/status/{job_id}")
def get_status(job_id: str):
    """Return latest lifecycle status for a single job.

    Adds a download URL only after a successful benchmark run.
    """
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT job_id, success, summary, status FROM jobs WHERE job_id = ? AND is_deleted = 0",
        (job_id,),
    ).fetchone()
    conn.close()

    if not row:
        return JSONResponse(status_code=404, content={"error": "Job not found"})

    _, success, summary, status = row

    # Convert nullable integer flag to JSON-friendly tri-state boolean.
    response = {
        "job_id": job_id,
        "success": None if success is None else bool(success),
        "summary": summary,
        "status": status,
    }

    # Always expose a Stage A download link if the draft exists.
    job_dir = JOBS_DIR / job_id
    stageA_path = job_dir / "stageA.v"
    if stageA_path.exists():
        response["stageA_download_url"] = f"/download/{job_id}?stage=stageA"

    if success == 1:
        # Download is only valid for successful job outputs (final optimized design).
        response["download_url"] = f"/download/{job_id}"

    return JSONResponse(content=response)


@app.get("/download/{job_id}")
def download_generated_file(job_id: str, stage: str | None = None):
    """Serve generated artifacts for a job.

    Query parameter `stage` may be `stageA` to retrieve the initial draft, or
    omitted to return the final `generated.v` artifact.
    """
    job_dir = JOBS_DIR / job_id
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT job_id FROM jobs WHERE job_id = ? AND is_deleted = 0",
        (job_id,),
    ).fetchone()
    conn.close()

    if not row:
        return JSONResponse(status_code=404, content={"error": "Job not found"})

    if stage == "stageA":
        file_path = job_dir / "stageA.v"
        download_name = "stageA.v"
    else:
        file_path = job_dir / "generated.v"
        download_name = "generated.v"

    # File may be absent if job failed or has not finished yet.
    if not file_path.exists():
        return JSONResponse(status_code=404, content={"error": "File not found"})

    return FileResponse(
        path=file_path,
        filename=download_name,
        media_type="text/plain",
    )


@app.get("/logs/{job_id}")
def get_logs(job_id: str):
    """Return captured simulation stdout/stderr for a job."""
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT job_id FROM jobs WHERE job_id = ? AND is_deleted = 0",
        (job_id,),
    ).fetchone()
    conn.close()

    if not row:
        return JSONResponse(status_code=404, content={"error": "Job not found"})

    stdout, stderr = read_logs(job_id)

    if not stdout and not stderr:
        # Keep 404 semantics so UI can distinguish "no logs yet" from empty logs.
        return JSONResponse(status_code=404, content={"error": "Logs not found"})

    return JSONResponse(
        content={
            "job_id": job_id,
            "stdout": stdout,
            "stderr": stderr,
        }
    )


@app.get("/history")
def get_history():
    # Most-recent-first ordering keeps the latest activity at the top of the UI.
    rows = conn.execute(
        """
        SELECT job_id, success, summary, status, created_at
        FROM jobs
        WHERE is_deleted = 0
        ORDER BY created_at DESC
        """
    ).fetchall()
    conn.close()

    jobs = []
    # Re-map DB rows into API schema expected by the frontend list renderer.
    for job_id, success, summary, status, created_at in rows:
        # Convert DB-native types into client-facing JSON values.
    # Re-map DB rows into API schema expected by the frontend list renderer.
    for job_id, success, summary, status, created_at in rows:
        job = {
            "job_id": job_id,
            "success": None if success is None else bool(success),
            "summary": summary,
            "status": status,
            "created_at": created_at,
        }
        # Always offer Stage A draft when present for debugging and access.
        job_dir = JOBS_DIR / job_id
        if (job_dir / "stageA.v").exists():
            job["stageA_download_url"] = f"/download/{job_id}?stage=stageA"

        if success == 1:
            job["download_url"] = f"/download/{job_id}"
        jobs.append(job)

    return JSONResponse(content={"jobs": jobs})


@app.delete("/history/{job_id}")
def remove_history_item(job_id: str):
    """Delete a single job from history and remove its artifacts."""
    if delete_job(job_id):
        return JSONResponse(content={"ok": True})
    return JSONResponse(status_code=404, content={"error": "Job not found"})


@app.delete("/history")
def clear_history():
    """Delete all visible history entries."""
    conn = sqlite3.connect(DB_PATH)
    # Snapshot IDs first so we can close DB before filesystem deletions.
    job_ids = [row[0] for row in conn.execute("SELECT job_id FROM jobs WHERE is_deleted = 0").fetchall()]
    conn.close()

    # Reuse single-item delete path so semantics stay consistent.
    for job_id in job_ids:
        delete_job(job_id)

    return JSONResponse(content={"ok": True, "deleted": len(job_ids)})


@app.get("/system-status")
def get_system_status():
    """Expose runtime health snapshot used by the frontend status pills.

    Notes:
    - Queue depth comes from Redis.
    - Model/processor state comes from Ollama.
    - Worker status is inferred from Ollama reachability.
    """
    # Queue depth is a quick signal of backlog pressure.
    queue_depth = redis_client.llen("hdl_jobs")

    # Keep the helper nested because it is only used by this endpoint.
    # Try to detect GPU programmatically rather than hardcoding.
    def detect_gpu() -> str:
        # 1) Environment hint for NVIDIA in container runtimes
        nv_env = os.environ.get("NVIDIA_VISIBLE_DEVICES")
        if nv_env and nv_env.lower() not in ("none", "void"):
            return f"NVIDIA ({nv_env})"

        # 2) /dev presence (typical when GPU device nodes are mounted)
        if Path("/dev/nvidia0").exists():
            # Prefer nvidia-smi output when available
            try:
                out = subprocess.check_output(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"], stderr=subprocess.DEVNULL, timeout=2)
                name = out.decode().splitlines()[0].strip()
                if name:
                    return name
            except Exception:
                return "NVIDIA (device)"

        # 3) /proc driver listing (NVIDIA exposes GPUs under this path)
        try:
            if Path("/proc/driver/nvidia/gpus").exists():
                # Return first GPU directory name if present
                entries = list(Path("/proc/driver/nvidia/gpus").iterdir())
                if entries:
                    return f"NVIDIA ({entries[0].name})"
        except Exception:
            pass

        # 4) Try ROCm (AMD) tooling
        try:
            out = subprocess.check_output(["rocm-smi", "-i"], stderr=subprocess.DEVNULL, timeout=2)
            lines = out.decode().splitlines()
            for line in lines:
                if line.strip():
                    return line.strip()
        except Exception:
            pass

        # 5) Sysfs /sys/class/drm card vendor sniffing (works in many Linux hosts)
        try:
            for path in glob.glob("/sys/class/drm/card*/device/vendor"):
                try:
                    vendor = Path(path).read_text().strip().lower()
                    # NVIDIA vendor id is 0x10de, AMD is 0x1002
                    if "0x10de" in vendor:
                        return "NVIDIA (PCI)"
                    if "0x1002" in vendor:
                        return "AMD (PCI)"
                except Exception:
                    continue
        except Exception:
            pass

        # 6) Command fallbacks: nvidia-smi then lspci
        try:
            out = subprocess.check_output(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"], stderr=subprocess.DEVNULL, timeout=2)
            name = out.decode().splitlines()[0].strip()
            if name:
                return name
        except Exception:
            pass

        try:
            out = subprocess.check_output(["lspci"], stderr=subprocess.DEVNULL, timeout=2)
            for line in out.decode().splitlines():
                if "vga" in line.lower() or "3d controller" in line.lower() or "display controller" in line.lower():
                    return line.split(':', 1)[1].strip()
        except Exception:
            pass

        return "unknown"
# Default values are optimistic but safe; they get refined below.
    gpu_name = detect_gpu()
    model_name = MODEL
    processor = "unknown"
    worker_status = "online"

    # Normalize verbose GPU descriptions into compact UI-friendly labels.    worker_status = "online"

    def trim_gpu_name(raw: str) -> str:
        """Return a short vendor+model string for display."""
        if not raw:
            return "unknown"
        s = raw.strip()
        if s.lower() == "unknown":
            return "unknown"

        # Prefer bracketed model names like '... [GeForce RTX 2080]'
        import re
        import subprocess

        m = re.search(r"\[(.*?)\]", s)
        if m:
            return m.group(1).strip()

        # If the value only indicates PCI/vendor, try lspci for a richer description.
        if "pci" in s.lower() or any(k in s for k in ("AMD", "NVIDIA", "Intel", "RADEON", "GEFORCE")):
            try:
                out = subprocess.check_output(["lspci", "-nn"], stderr=subprocess.DEVNULL, timeout=2)
                text = out.decode(errors="ignore")
                # Prefer lines that mention known vendors and include model text.
                for line in text.splitlines():
                    low = line.lower()
                    if "advanced micro devices" in low or "amd" in low or "nvidia" in low or "geforce" in low or "radeon" in low:
                        # Extract description after the first colon
                        if ":" in line:
                            desc = line.split(":", 1)[1].strip()
                            desc = re.sub(r"\s+", " ", re.sub(r"[\(\)]", "", desc))
                            return desc
                # As a last resort, return the first VGA/3D line description
                for line in text.splitlines():
                    low = line.lower()
                    if "vga compatible controller" in low or "3d controller" in low or "display controller" in low:
                        if ":" in line:
                            return line.split(":", 1)[1].strip()
            except Exception:
                pass

        # Look for common vendors and return vendor + following tokens
        vendors = ["NVIDIA", "AMD", "INTEL", "GEFORCE", "RADEON", "TESLA"]
        lower = s.lower()
        for v in vendors:
            if v.lower() in lower:
                # Extract from vendor occurrence to end, remove 'Corporation' and excess punctuation
                idx = lower.index(v.lower())
                part = s[idx:]
                part = re.sub(r"Corporation", "", part, flags=re.I)
                part = re.sub(r"\s+", " ", part)
                part = re.sub(r"[,\(\)]", "", part)
                return part.strip()

        # Fallback: return first three words of the string
        parts = s.split()
        return " ".join(parts[:3]) if len(parts) >= 3 else s

    try:
        # Ollama ps exposes loaded model metadata and processor mode.
        response = requests.get("http://ollama:11434/api/ps", timeout=5)
        response.raise_for_status()
        data = response.json()
        models = data.get("models", [])

        if models:
            first = models[0]
            model_name = first.get("name", MODEL)
            processor = first.get("processor", "unknown")
            # If Ollama doesn't report processor, infer from detected GPU or common hints.
            if not processor or processor == "unknown":
                # Look for other possible keys that may indicate device
                processor_hint = first.get("device") or first.get("processor_type") or first.get("host_processor")
                if processor_hint:
                    processor = processor_hint
                else:
                    # If a GPU is present on the host, assume the model will use GPU; otherwise CPU.
                    processor = "gpu" if gpu_name and gpu_name != "unknown" else "cpu"
        else:
            # API reachable but no active model loaded yet.
            processor = "idle"
    except Exception:
        # Keep endpoint resilient even if Ollama is temporarily unavailable.
        processor = "unreachable"
        worker_status = "unknown"

    return JSONResponse(
        content={
            "gpu": gpu_name,
            "gpu_short": trim_gpu_name(gpu_name),
            "model": model_name,
            "processor": processor,
            "worker": worker_status,
            "queue_depth": queue_depth,
        }
    )
