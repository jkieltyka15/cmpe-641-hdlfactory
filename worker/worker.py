"""HDLFACTORY queue worker.

Consumes queued jobs from Redis, generates Verilog with Ollama, validates output
with Verilator, then persists status/log artifacts for API retrieval.
"""

import json
import os
import re
import sqlite3
import subprocess
from pathlib import Path
import shutil

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


def available_threads() -> int:
    """Return the CPU count visible to the current process."""
    try:
        return len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        return os.cpu_count() or 1


MAX_THREADS = max(1, available_threads())


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

Assume the user's request is for a synthesizable hardware design unless it
explicitly asks for something else. If the request is ambiguous, infer a
synthesizable RTL implementation.

Task:
{prompt}

Rules:
- Output ONLY synthesizable Verilog code
- No markdown
- No explanation
- No testbench
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


def run_benchmark(job_dir: Path, source_file: str = "generated.v"):
    """Compile and run a Verilog source against benchmark_tb.v using Verilator.

    Args:
        job_dir: Job workspace containing HDL artifacts and benchmark testbench.
        source_file: Verilog file to compile (for example `generated.v` or
            `optimized.v`).
    """
    # If the requested source file is missing (for example older worker runs
    # that didn't write `generated.v`), fall back to `stageA.v` when present.
    src_path = job_dir / source_file
    if not src_path.exists():
        fallback = job_dir / "stageA.v"
        if fallback.exists():
            # Record a short diagnostic note so UI can show why we fell back.
            note = (
                f"Note: requested source '{source_file}' missing, falling back to 'stageA.v'\n"
            )
            # Append diagnostic so it surfaces in the frontend logs.
            try:
                with (job_dir / "stderr.log").open("a", encoding="utf-8") as f:
                    f.write(note)
            except Exception:
                pass

            # Copy the available Stage A draft to `generated.v` so any existing
            # Verilator invocation that expects `generated.v` will succeed.
            try:
                shutil.copyfile(fallback, job_dir / "generated.v")
                source_file = "generated.v"
            except Exception:
                # If copy fails for any reason, fall back to using stageA.v
                source_file = "stageA.v"
        else:
            # Neither the requested file nor a fallback exists — return a
            # CompletedProcess-like failure so callers can handle it uniformly.
            return subprocess.CompletedProcess(args=[], returncode=1, stdout="", stderr=f"Source file {source_file} not found")

    # Recompute source path after any fallback/copy adjustments.
    src_path = job_dir / source_file

    # Build and execute in a single shell so relative paths resolve in job dir.
    cmd = [
        "bash",
        "-lc",
        f"cd {job_dir} && verilator --binary --threads {MAX_THREADS} -j 0 --top-module benchmark_tb {source_file} benchmark_tb.v && ./obj_dir/Vbenchmark_tb",
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
            "Step 1 of 5: Generating Verilog with Mistral-7B...",
            "generating",
        )

        verilog_text = generate_verilog(prompt)
        # Persist the raw stage A draft so users can always download it.
        stageA_path = job_dir / "stageA.v"
        stageA_path.write_text(verilog_text + "\n", encoding="utf-8")
        # Stage A benchmark flow still expects `generated.v`; write the same
        # draft there before running Verilator so existing compile commands work.
        generated_path.write_text(verilog_text + "\n", encoding="utf-8")

        # Diagnostic print helps confirm whether inference used CPU or GPU.
        detect_processor()

        # Stage 2: compile + execute benchmark testbench against stage A.
        update_job(
            job_id,
            None,
            "Step 2 of 5: Running Verilator benchmark on Stage A...",
            "simulating_stageA",
        )

        # Preserve raw simulator output so users can inspect failures in UI.
        result = run_benchmark(job_dir, source_file="stageA.v")
        (job_dir / "stdout.log").write_text(result.stdout, encoding="utf-8")
        (job_dir / "stderr.log").write_text(result.stderr, encoding="utf-8")

        stageA_success = result.returncode == 0 and "TEST PASSED" in result.stdout
        stageA_summary = summarize_result(result.stdout, result.stderr, result.returncode)

        if not stageA_success:
            # If Stage A fails, allow users to download the Stage A draft and stop.
            update_job(
                job_id,
                0,
                f"Step 2 of 5: Stage A failed: {stageA_summary}",
                "failed",
            )
            return

        # Stage 3: optimize with codestral:22B via Ollama model endpoint.
        update_job(
            job_id,
            None,
            "Step 3 of 5: Optimizing design with codestral:22B...",
            "optimizing",
        )

        optimized_path = job_dir / "optimized.v"
        codestral_stdout = job_dir / "codestral_stdout.log"
        codestral_stderr = job_dir / "codestral_stderr.log"

        try:
            # Call Ollama generate endpoint using codestral:22B as the model.
            # Provide the Stage A Verilog as the prompt and ask the model to
            # return an optimized Verilog implementation only.
            with stageA_path.open("r", encoding="utf-8") as f:
                stageA_text = f.read()

            optimize_prompt = f"""You are an HDL optimizer model.

Task:
Optimize the following Verilog for physical size and power while preserving
its functional behavior. Output ONLY Verilog code (no markdown or commentary).

Input Verilog:
{stageA_text}
"""

            payload = {
                "model": "codestral:22B",
                "prompt": optimize_prompt,
                "stream": False,
            }

            resp = requests.post(OLLAMA_URL, json=payload, timeout=300)
            resp.raise_for_status()
            data = resp.json()
            optimized_text = clean_verilog(data.get("response", ""))

            codestral_stdout.write_text(data.get("response", ""), encoding="utf-8")
            codestral_stderr.write_text("", encoding="utf-8")

            if not optimized_text.strip():
                update_job(
                    job_id,
                    0,
                    "Step 3 of 5: codestral produced no output.",
                    "failed",
                )
                return

            optimized_path.write_text(optimized_text + "\n", encoding="utf-8")
        except Exception as e:
            # Record Ollama optimization failures as terminal for Stage B.
            codestral_stderr.write_text(str(e), encoding="utf-8")
            update_job(job_id, 0, f"Step 3 of 5: codestral error: {str(e)}", "failed")
            return

        # Stage 4: run Verilator on the optimized output to sanity-check behavior.
        update_job(
            job_id,
            None,
            "Step 4 of 5: Running Verilator benchmark on optimized design...",
            "simulating_optimized",
        )

        # Reuse the same benchmark flow for the optimized Stage B candidate.
        opt_result = run_benchmark(job_dir, source_file="optimized.v")
        (job_dir / "opt_stdout.log").write_text(opt_result.stdout, encoding="utf-8")
        (job_dir / "opt_stderr.log").write_text(opt_result.stderr, encoding="utf-8")

        if opt_result.returncode != 0 or "TEST PASSED" not in opt_result.stdout:
            summary = summarize_result(opt_result.stdout, opt_result.stderr, opt_result.returncode)
            update_job(
                job_id,
                0,
                f"Step 4 of 5: Optimized design failed: {summary}",
                "failed",
            )
            return

        # Stage 5: final testing with Icarus Verilog for benchmarking.
        update_job(
            job_id,
            None,
            "Step 5 of 5: Running Icarus Verilog on optimized design...",
            "running_icarus",
        )

        icarus_cmd = [
            "bash",
            "-lc",
            f"cd {job_dir} && iverilog -o sim_icarus.vvp optimized.v benchmark_tb.v && vvp sim_icarus.vvp",
        ]
        icarus_result = subprocess.run(icarus_cmd, capture_output=True, text=True)
        (job_dir / "icarus_stdout.log").write_text(icarus_result.stdout, encoding="utf-8")
        (job_dir / "icarus_stderr.log").write_text(icarus_result.stderr, encoding="utf-8")

        if icarus_result.returncode != 0 or "TEST PASSED" not in icarus_result.stdout:
            summary = summarize_result(icarus_result.stdout, icarus_result.stderr, icarus_result.returncode)
            update_job(
                job_id,
                0,
                f"Step 5 of 5: Icarus Verilog failed: {summary}",
                "failed",
            )
            return

        # All stages passed: write the optimized design as the canonical downloadable
        # `generated.v` so frontend download links continue to work as before.
        final_path = job_dir / "generated.v"
        optimized_path.replace(final_path)

        # Consolidated final logs for UI convenience.
        (job_dir / "stdout.log").write_text(icarus_result.stdout, encoding="utf-8")
        (job_dir / "stderr.log").write_text(icarus_result.stderr, encoding="utf-8")

        update_job(
            job_id,
            1,
            "Step 5 of 5: Optimized design passed all tests.",
            "completed",
        )

    except Exception as e:
        # Record unexpected worker-side exceptions as terminal failures and keep
        # the Stage A draft available for download to aid debugging.
        (job_dir / "stderr.log").write_text(str(e), encoding="utf-8")
        update_job(
            job_id,
            0,
            f"Worker error: {str(e)}",
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
