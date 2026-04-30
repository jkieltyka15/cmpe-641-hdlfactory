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
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY,
            prompt TEXT,
            success INTEGER,
            summary TEXT,
            status TEXT,
            created_at TEXT
        )
        """
    )
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
        "SELECT job_id FROM jobs WHERE job_id = ?",
        (job_id,),
    ).fetchone()

    if not existing:
        # First write for a job creates the canonical row.
        conn.execute(
            """
            INSERT INTO jobs (job_id, prompt, success, summary, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
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
        "SELECT job_id, success, summary, status FROM jobs WHERE job_id = ?",
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
    """Return all jobs ordered by newest first for dashboard history."""
    conn = sqlite3.connect(DB_PATH)
    rows = conn.execute(
        """
        SELECT job_id, success, summary, status, created_at
        FROM jobs
        ORDER BY created_at DESC
        """
    ).fetchall()
    conn.close()

    jobs = []
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

    # GPU is currently reported as static metadata for this deployment.
    gpu_name = "AMD RX 5700"
    model_name = MODEL
    processor = "unknown"
    worker_status = "online"

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
            "model": model_name,
            "processor": processor,
            "worker": worker_status,
            "queue_depth": queue_depth,
        }
    )
