"""HDLFACTORY queue worker.

Consumes queued jobs from Redis, generates Verilog with Ollama, validates output
with Verilator, then persists status/log artifacts for API retrieval.
"""

import json
import re
import sqlite3
import subprocess
from pathlib import Path

import redis
import requests

OLLAMA_URL = "http://ollama:11434/api/generate"
OLLAMA_PS_URL = "http://ollama:11434/api/ps"
MODEL = "mistral:7b"

# Worker runs inside /app and shares mounted job/data folders with backend.
BASE_DIR = Path("/app")
JOBS_DIR = BASE_DIR / "jobs"
DATA_DIR = BASE_DIR / "data"
DB_PATH = DATA_DIR / "jobs.db"

# Redis list `hdl_jobs` contains serialized job payloads from backend.
redis_client = redis.Redis(host="redis", port=6379, decode_responses=True)


def clean_verilog(text: str) -> str:
    """Normalize model output to pure Verilog.

    LLM responses may include markdown fences or extra prose. This routine keeps
    the first module...endmodule block when available.
    """
    # Remove common markdown wrappers before regex extraction.
    text = text.replace("```verilog", "").replace("```", "").strip()
    match = re.search(r"(module\b.*?endmodule)", text, re.DOTALL)
    if match:
        # Prefer the first complete module block over extra prose.
        return match.group(1).strip()
    return text


def generate_verilog(prompt: str) -> str:
    """Request Verilog from Ollama using a constrained generation prompt."""
    full_prompt = f"""You are a Verilog code generator.

Task:
{prompt}

Rules:
- Output ONLY Verilog code
- No markdown
- No explanation
- Must compile with Verilator
"""

    payload = {
        "model": MODEL,
        "prompt": full_prompt,
        "stream": False,
    }

    # Long timeout accounts for first-token latency on large model runs.
    response = requests.post(OLLAMA_URL, json=payload, timeout=300)
    response.raise_for_status()
    data = response.json()
    return clean_verilog(data["response"])


def summarize_result(stdout: str, stderr: str, returncode: int) -> str:
    """Generate a concise status summary suitable for UI display."""
    # Success requires both zero exit code and explicit benchmark pass marker.
    if returncode == 0 and "TEST PASSED" in stdout:
        return "Generated Verilog passed the benchmark."

    # Prefer explicit syntax diagnostics when available.
    if "syntax error" in stderr.lower():
        return "Generated Verilog failed due to a syntax error."

    # Benchmarks often emit FAIL lines even when compilation succeeded.
    if "FAIL:" in stdout:
        return "Generated Verilog compiled, but failed the benchmark checks."

    # Otherwise surface the most relevant final line from stderr/stdout.
    if stderr.strip():
        return stderr.strip().splitlines()[-1]

    if stdout.strip():
        return stdout.strip().splitlines()[-1]

    return "Validation failed for an unknown reason."


def update_job(job_id: str, success, summary: str, status: str):
    """Persist latest job state in SQLite.

    Args:
        job_id: Job UUID.
        success: None while running, else 1/0 terminal result.
        summary: Human-readable status line for frontend display.
        status: State token such as generating/simulating/completed/failed.
    """
    # Keep DB writes explicit and short to minimize lock contention.
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "UPDATE jobs SET success = ?, summary = ?, status = ? WHERE job_id = ?",
        (success, summary, status, job_id),
    )
    conn.commit()
    conn.close()


def run_benchmark(job_dir: Path):
    """Compile and run generated.v against benchmark_tb.v using Verilator."""
    # Build and execute in a single shell so relative paths resolve in job dir.
    cmd = [
        "bash",
        "-lc",
        f"cd {job_dir} && verilator --binary --top-module benchmark_tb generated.v benchmark_tb.v && ./obj_dir/Vbenchmark_tb",
    ]
    return subprocess.run(cmd, capture_output=True, text=True)


def detect_processor():
    """Print active model processor mode (CPU/GPU) for diagnostics."""
    try:
        result = requests.get(OLLAMA_PS_URL, timeout=10)
        result.raise_for_status()
        data = result.json()

        models = data.get("models", [])
        if not models:
            print("MODEL PROCESSOR: NO MODEL LOADED")
            return

        processor = models[0].get("processor", "UNKNOWN")
        print(f"MODEL PROCESSOR: {processor}")
    except Exception:
        # Non-fatal: generation can still proceed even if this probe fails.
        print("MODEL PROCESSOR: UNKNOWN")


def process_job(job):
    """Run the full pipeline for one dequeued job payload.

    Side effects:
    - Writes generated HDL and simulation logs into the job directory.
    - Updates DB status for each stage and terminal outcome.
    """
    # Job payload shape is produced by backend /generate endpoint.
    job_id = job["job_id"]
    prompt = job["prompt"]
    job_dir = JOBS_DIR / job_id
    generated_path = job_dir / "generated.v"

    try:
        # Stage 1: model generation.
        update_job(
            job_id,
            None,
            "Step 1 of 3: Generating Verilog with Mistral-7B...",
            "generating",
        )

        verilog_text = generate_verilog(prompt)
        generated_path.write_text(verilog_text + "\n", encoding="utf-8")

        # Diagnostic print helps confirm whether inference used CPU or GPU.
        detect_processor()

        # Stage 2: compile + execute benchmark testbench.
        update_job(
            job_id,
            None,
            "Step 2 of 3: Running Verilator benchmark...",
            "simulating",
        )

        # Preserve raw simulator output so users can inspect failures in UI.
        result = run_benchmark(job_dir)

        # Persist raw logs for troubleshooting in frontend history view.
        (job_dir / "stdout.log").write_text(result.stdout, encoding="utf-8")
        (job_dir / "stderr.log").write_text(result.stderr, encoding="utf-8")

        success = result.returncode == 0 and "TEST PASSED" in result.stdout
        summary = summarize_result(result.stdout, result.stderr, result.returncode)

        # Stage 3: terminal status presented directly in UI.
        final_summary = f"Step 3 of 3: {summary}"

        update_job(
            job_id,
            1 if success else 0,
            final_summary,
            "completed" if success else "failed",
        )

    except Exception as e:
        # Record unexpected worker-side exceptions as terminal failures.
        (job_dir / "stderr.log").write_text(str(e), encoding="utf-8")
        update_job(
            job_id,
            0,
            f"Step 3 of 3: Worker error: {str(e)}",
            "failed",
        )


def main():
    """Start the long-running Redis consumer loop."""
    print("HDLFACTORY worker starting...")
    detect_processor()

    while True:
        # Blocking pop keeps the worker idle without busy polling.
        _, job_json = redis_client.blpop("hdl_jobs")
        # Redis returns JSON string payload; decode then process.
        job = json.loads(job_json)
        process_job(job)


if __name__ == "__main__":
    main()
