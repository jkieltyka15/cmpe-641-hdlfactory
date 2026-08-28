# HDLFACTORY

**AI-Powered HDL Generation, Optimization, and Validation Platform**

HDLFACTORY is an end-to-end system for generating synthesizable Verilog hardware designs from natural language specifications, automatically optimizing them for physical size and power, and validating them against user-provided testbenches. It leverages large language models (Ministral-3 (3B) for generation, Codestral-22B for optimization) and industry-standard tools (Verilator, Icarus Verilog) to produce production-ready RTL artifacts.

Development of this project was assisted by AI tools for implementation and documentation support.

## Paper Release

This repository contains the `v1.0.0` release associated with the paper
"HDLFACTORY: A Lightweight Open-Source Multi-Agent Framework for Verilog
Generation, Optimization, and Validation Using Large Language Models." See
[`CHANGELOG.md`](CHANGELOG.md) for the release contents and [`CITATION.cff`](CITATION.cff)
for the citation metadata.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Frontend (SPA)                       │
│                       nginx static site                     │
│                  (port 8080, index.html)                    │
└──────────────────┬────────────────────┬─────────────────────┘
                   │ REST API requests  │
                   ▼                    ▼
           ┌──────────────────────────────────┐
           │   Backend (FastAPI)              │
           │  POST /generate                  │
           │  GET /status/{id}                │
           │  GET /history                    │
           │  DELETE /history/{id}            │
           │  GET /logs/{id}                  │
           │  GET /download/{id}              │
           │  GET /system-status              │
           └──────┬──────────────┬────────────┘
                  │              │
       Job Queue  │              │ SQLite
       (Redis)    ▼              ▼ (jobs.db)
           ┌──────────────────────────────────┐
           │   Job State & Artifacts          │
           │   (Shared Volume)                │
           └───────┬──────────────────────────┘
                   │
           (Worker consumes queue)
                   ▼
            ┌──────────────────────────────────┐
            │    Worker (async processor)      │
            │  1. Generate Verilog (Ministral-3)   │
           │  2. Validate (Verilator)         │
           │  3. Optimize (Codestral)         │
           │  4. Validate opt. (Verilator)    │
           │  5. Final test (Icarus Verilog)  │
           └───────┬──────────────────────────┘
                   │
        ┌──────────┴──────────┬────────────┐
        ▼                     ▼            ▼
    ┌─────────┐         ┌──────────┐  ┌──────────┐
    │ Ollama  │         │ Verilator│  │ Icarus   │
    │ Runtime │         │ (compile │  │ Verilog  │
    │ Models  │         │  +sim)   │  │ (sim)    │
    │ (GPU)   │         └──────────┘  └──────────┘
    └─────────┘
```

## Quick Start

### Prerequisites

- **Docker & Docker Compose** (v2.0+)
- **GPU Support** (recommended for Ollama inference; CPU-only mode available)
  - NVIDIA GPU with CUDA support (or AMD with ROCm)
  - GPU device nodes mounted into containers (already configured in docker-compose.yml)
- **At least 32 GB free disk space** (for model cache and job artifacts)
- **8+ CPU cores** (for parallel Verilator compilation and simulation)

### Installation & Startup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/jkieltyka15/cmpe-641-hdlfactory.git
   cd cmpe-641-hdlfactory
   ```

2. **Start all services:**
   ```bash
   docker-compose up -d
   ```

   This will:
   - Pull and build all service images (backend, worker, frontend, verilator)
   - Start Redis and Ollama services
   - Pre-pull LLM models (Ministral-3 (3B), Codestral-22B) — this takes ~5–10 minutes on first run
   - Start the FastAPI backend, async worker, and nginx frontend
   - Initialize SQLite job database

3. **Access the UI:**
   Open your browser to **http://localhost:8080**

4. **Check system health:**
   The System Status panel shows:
   - GPU availability
   - Active model and processor mode (CPU/GPU)
   - Redis queue depth
   - Worker connectivity

### Basic Usage Flow

1. **Create a job:**
   - Go to the **Create Job** tab
   - Write a natural language prompt describing the hardware design you want
   - Upload a benchmark testbench file (Verilog)
     - The testbench can be named anything (e.g., `my_test.v`, `adder32_tb.v`, etc.)
     - The module name inside the file must match the filename
   - Click **Generate**

2. **Monitor progress:**
   - The status updates through 5 stages in real-time:
     1. **Generating Verilog** – LLM creates initial design
     2. **Simulating Stage A** – Verilator validates the generated code
     3. **Optimizing** – Codestral-22B improves design for area/power
     4. **Simulating Optimized** – Verilator validates the optimized version
     5. **Running Icarus Verilog** – Final compliance check with Icarus

3. **Download artifacts:**
   - After successful completion, download the final optimized design as `<module_name>.v`
   - Or download the initial draft anytime (even if final optimization failed) as `<module_name>_draft.v`
   - For example, if the generated module is named `adder32`, downloads are `adder32.v` and `adder32_draft.v`

4. **View history:**
   - **Job History** tab shows all past runs
   - Click a job to see detailed logs
   - Delete single jobs or clear entire history

## API Reference

All endpoints return JSON. Base URL: `http://localhost:8080/api` (or direct backend on port 8000).

### POST /generate

**Create a new generation job.**

```bash
curl -X POST http://localhost:8080/api/generate \
  -F "prompt=Design a 4-bit ripple carry adder" \
  -F "benchmark_file=@benchmark_tb.v"
```

**Response:**
```json
{
  "job_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "status": "queued",
  "success": null,
  "summary": "Job queued."
}
```

### GET /status/{job_id}

**Check job status and download links.**

```bash
curl http://localhost:8080/api/status/f47ac10b-58cc-4372-a567-0e02b2c3d479
```

**Response (pending):**
```json
{
  "job_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "status": "simulating_stageA",
  "success": null,
  "summary": "Step 2 of 5: Running Verilator benchmark on Stage A...",
  "stageA_download_url": "/download/f47ac10b-58cc-4372-a567-0e02b2c3d479?stage=stageA"
}
```

**Response (success):**
```json
{
  "job_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "status": "completed",
  "success": true,
  "summary": "Step 5 of 5: Optimized design passed all tests.",
  "download_url": "/download/f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "stageA_download_url": "/download/f47ac10b-58cc-4372-a567-0e02b2c3d479?stage=stageA"
}
```

Note: The actual downloaded filenames are based on the generated module name (e.g., `adder32.v` or `adder32_draft.v`).

### GET /logs/{job_id}

**Retrieve simulation stdout and stderr.**

```bash
curl http://localhost:8080/api/logs/f47ac10b-58cc-4372-a567-0e02b2c3d479
```

### GET /history

**List all jobs, newest first.**

```bash
curl http://localhost:8080/api/history
```

### GET /download/{job_id}?stage=[stageA|final]

**Download generated Verilog artifacts.**

- `?stage=stageA` – Initial draft (if available), served as `<module_name>_draft.v`
- `?stage=final` (or omitted) – Final optimized version, served as `<module_name>.v`
- The actual filename is based on the generated module name for clarity

### DELETE /history/{job_id}

**Delete a single job and remove its artifacts.**

### DELETE /history

**Clear entire history.**

### GET /system-status

**Get runtime health snapshot (GPU, model, queue, worker status).**

```bash
curl http://localhost:8080/api/system-status
```

## Project Structure

```
hdlfactory/
├── README.md                      # This file
├── docker-compose.yml             # Service orchestration & volumes
│
├── frontend/                      # Static SPA
│   ├── Dockerfile                 # nginx serving
│   ├── index.html                 # Single-page application
│   └── nginx.conf                 # Static site routing
│
├── backend/                       # FastAPI service
│   ├── app.py                     # REST endpoints & job management
│   ├── Dockerfile                 # Python runtime
│   ├── requirements.txt           # Dependencies
│   ├── data/                      # SQLite database (persistent)
│   │   └── jobs.db                # Job metadata and status
│   └── jobs/                      # Job artifacts (shared with worker)
│       └── {job_id}/              # Per-job directory
│           ├── prompt.txt         # Original user request
	│           ├── <testbench_name>   # Uploaded testbench (any .v filename)
	│           ├── testbench_metadata.json  # Testbench & generated module metadata
	│           ├── stageA.v           # Initial generated design (internal)
	│           ├── generated.v        # Final optimized design (internal)
│           ├── optimized.v        # Intermediate optimization candidate
│           ├── stdout.log         # Final simulation output
│           ├── stderr.log         # Final simulation errors
│           ├── codestral_stdout.log
│           ├── opt_stdout.log     # Optimized design sim output
│           ├── opt_stderr.log
│           ├── icarus_stdout.log  # Icarus Verilog sim output
│           └── icarus_stderr.log
│
├── worker/                        # Async job processor
│   ├── worker.py                  # 5-stage pipeline & Ollama integration
│   ├── Dockerfile                 # Python + tools
│   └── requirements.txt           # Dependencies
│
├── verilator/                     # Verilator compilation environment
│   └── Dockerfile                 # C++ toolchain & Verilator
│
└── codestral/                     # (Optimization via Ollama model)
    └── Dockerfile                 # (Optional; not directly used)

└── tests/                         # Testing and synthesis flows
    ├── unified_synopsys_flow.tcl   # DC/ICC2 synthesis script
    ├── adder32/                    # Example designs for testing
    ├── alu32/
    ├── counter8/
    ├── decoder3x8/
    └── mux4x16/
```

## Running Synopsys Synthesis Flows

The `tests/unified_synopsys_flow.tcl` script automates Design Compiler (DC) and ICC2 synthesis flows for SAED 14nm technology. It can process generated Verilog designs or testbench-compatible HDL.

### Prerequisites

- **UMBC Synopsys License & Tools** (DC and ICC2 installed and licensed)
- **SAED 14nm Design Kit** (design_kits/SAED14nm, standard on UMBC servers)
- **Generated Verilog** (from HDLFACTORY or manual design)
- **Access to UMBC launch scripts** (`launch_synopsys_dc.sh`, `launch_synopsys_icc2_shell.sh`)

### Running Design Compiler (DC)

DC performs synthesis, optimization, and place & route preparation. Typical runtime: 2–10 minutes depending on design complexity.

**Command:**
```bash
env FLOW=dc RTL_FILE=verilog/adder32_draft.v TOP=adder32 CLK_PORT=clk CLK_PER=1.0 \
  /umbc/software/scripts/launch_synopsys_dc.sh \
    -f tests/unified_synopsys_flow.tcl -o dc_out.log
```

**Environment Variables:**
- `FLOW=dc` – Select Design Compiler flow
- `RTL_FILE` – Path to Verilog file (relative or absolute)
- `TOP` – Top-level module name (defaults to filename stem if omitted)
- `CLK_PORT` – Clock port name (default: `clk`)
- `CLK_PER` – Clock period in nanoseconds (default: `1.0`)

**Output Files (in `asic/reports/`):**
- `dc_area.rpt` – Area breakdown and utilization
- `dc_power.rpt` – Dynamic and leakage power estimates
- `dc.ddc` – Compiled design database (binary format)
- `dc_final.v` – Gate-level Verilog netlist

**Output Directories:**
- `asic/work/` – DC working files and intermediate databases
- `gate/` – Gate-level netlists and SDF timing files

### Running ICC2 (Place & Route)

ICC2 performs floorplanning, placement, routing, and final timing verification. Run this **after DC completes successfully**. Typical runtime: 5–30 minutes depending on size.

**Command:**
```bash
env FLOW=icc2 RTL_FILE=verilog/adder32_draft.v TOP=adder32 CLK_PORT=clk CLK_PER=1.0 \
  /umbc/software/scripts/launch_synopsys_icc2_shell.sh \
    -f tests/unified_synopsys_flow.tcl -o icc2_out.log
```

**Output Files (in `asic/reports/`):**
- `icc2_area.rpt` – Final placed & routed area utilization
- `icc2_power.rpt` – Post-route power analysis
- `icc2_timing.rpt` – Setup/hold timing closure status
- `icc2_wns.rpt` – Worst negative slack (if any timing violations)
- `icc2_routing.rpt` – Congestion and route utilization metrics

**Output GDS & Netlists:**
- `asic/work/` – ICC2 library, macro placements, routing database
- `gate/icc2_final.gds` – Final GDS2 layout (if GDS export enabled)
- `gate/icc2_final.v` – Final routed netlist

### Example Workflow

```bash
# 1. Generate a design with HDLFACTORY, download to verilog/adder32_draft.v
cd /home/student/hdlfactory-run

# 2. Run DC synthesis
env FLOW=dc RTL_FILE=verilog/adder32_draft.v TOP=adder32 CLK_PORT=clk CLK_PER=1.0 \
  /umbc/software/scripts/launch_synopsys_dc.sh \
    -f tests/unified_synopsys_flow.tcl -o dc.log

# 3. Check DC completed successfully
grep -i "error\|warning" dc.log | head -20
tail -50 dc.log | grep -i "total area\|power"

# 4. Run ICC2 (place & route)
env FLOW=icc2 RTL_FILE=verilog/adder32_draft.v TOP=adder32 CLK_PORT=clk CLK_PER=1.0 \
  /umbc/software/scripts/launch_synopsys_icc2_shell.sh \
    -f tests/unified_synopsys_flow.tcl -o icc2.log

# 5. Review final metrics
tail -100 icc2.log | grep -A 20 "FINAL ICC2 METRICS"
cat asic/reports/icc2_area.rpt
cat asic/reports/icc2_power.rpt
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| "RTL_FILE not specified" | Pass `-rtl ./path/to/file.v` or set `RTL_FILE=` environment variable before running |
| "TOP module not found" | Ensure `TOP=` matches the module name inside the Verilog file, or set `TOP=` explicitly |
| DC/ICC2 license errors | Verify UMBC license server is accessible; check `flexlmdiag` on UMBC systems |
| Clock period too tight | Increase `CLK_PER` value (e.g., `CLK_PER=2.0` for slower timing closure) |
| Memory/timeout errors | Very large designs may exceed allocated resources; break into smaller modules or use incremental compilation |
| Reports missing | Check `dc_out.log` or `icc2_out.log` for Tcl errors; verify `asic/reports/` directory was created |

### Advanced Options

The script reads configuration from environment variables, command-line arguments (`-rtl`, `-top`, `-clk`, `-period`), or defaults. Customization points:

- **Technology node**: Edit `DESIGN_REF_PATH` in the script to use a different design kit
- **Library selection**: Modify `TARGET_LIBRARY_FILES` (currently: SAED 14nm RVT)
- **Power supply nets**: Adjust `NDM_POWER_NET`, `NDM_POWER_PORT`, `NDM_GROUND_NET`, `NDM_GROUND_PORT` for custom power/ground naming
- **Routing layers**: Change `MIN_ROUTING_LAYER` and `MAX_ROUTING_LAYER` to constrain routing to specific metal layers

## Worker Pipeline Stages

The worker implements a five-stage pipeline:

### Stage 1: Verilog Generation (Ministral-3 (3B))
- Ollama generate endpoint receives the user prompt
- Ministral-3 (3B) produces synthesizable Verilog code
- Output is cleaned (markdown stripped) and written to `stageA.v`
- Generated module name is extracted and stored in metadata
- **Timescale matching**: Testbench timescale is automatically prepended to all generated code to ensure Verilator compatibility

### Stage 2: Stage A Validation (Verilator)
- Verilator compiles `stageA.v` against the uploaded testbench file
- Testbench filename, module name, and timescale are read from metadata
- The generated code has the testbench timescale prepended internally for compilation
- If compilation or simulation fails, job terminates with error
- If testbench passes, proceeds to optimization

### Stage 3: Optimization (Codestral-22B)
- Codestral-22B reads `stageA.v` and produces optimized Verilog
- Optimization targets area and power reduction while preserving behavior
- **Interface Preservation**: The optimization prompt explicitly constrains the model to:
  - NOT change module ports (inputs, outputs, bit widths)
  - NOT alter functional behavior or port semantics
  - Return input unchanged if optimization is uncertain
- **Port Validation**: The generated optimized code is validated to ensure:
  - All output ports match the original in name and bit width
  - Port structure is identical to Stage A
  - If port structure differs, optimization is rejected
- Result written to `optimized.v`

### Stage 4: Optimized Design Validation (Verilator)
- Verilator compiles and simulates `optimized.v` against the uploaded testbench
- If testbench **passes**: proceeds to final validation with Stage 5
- If testbench **fails**: 
  - Automatically falls back to Stage A (`stageA.v`) as the final design
  - Re-runs simulation with Stage A to confirm it passes
  - If Stage A fallback also fails (unexpected): job terminates with error
  - If Stage A fallback passes: continues to Stage 5 with Stage A instead
  - Either way, users receive a working design or a clear error message
- Stage A draft is always available for download, regardless of optimization outcome

### Stage 5: Final Validation (Icarus Verilog)
- Icarus Verilog runs simulation as final compliance check against the uploaded testbench
- Upon success, `optimized.v` is copied to `generated.v` for download
- Downloads are served with dynamic filenames based on module name: `<module_name>.v` and `<module_name>_draft.v`
- Consolidated logs written for frontend display

If any stage fails, the job is marked as failed, but `stageA.v` remains available for debugging.

## Configuration

### Environment Variables

**Backend & Worker:**
- `OLLAMA_URL` – Ollama API endpoint (default: `http://ollama:11434/api/generate`)
- `MODEL` – Generation model name (default: `ministral-3:3b`)

**Docker Compose:**
- `OLLAMA_VULKAN=1` – Enable Vulkan acceleration for AMD GPUs
- GPU device mounting uses `/dev/dri:/dev/dri` for both NVIDIA and AMD

### Database Schema

The SQLite `jobs` table:

```sql
CREATE TABLE jobs (
  job_id TEXT PRIMARY KEY,
  prompt TEXT,
  success INTEGER,           -- NULL: pending, 0: failed, 1: success
  summary TEXT,              -- Human-readable status line
  status TEXT,               -- queued, generating, simulating_stageA, optimizing, etc.
  created_at TEXT,           -- ISO 8601 timestamp
  is_deleted INTEGER          -- Soft-delete flag (0: visible, 1: hidden)
);
```

The `testbench_metadata.json` file (in each job directory) stores:

```json
{
  "testbench_file": "<uploaded_filename>",
  "testbench_module": "<module_name_from_testbench>",
  "testbench_timescale": "`timescale 1ns/1ps",
  "generated_module": "<module_name_from_generated_code>"
}
```

This metadata enables:
- Support for testbenches with any filename (not hardcoded to `benchmark_tb.v`)
- Dynamic compilation commands with correct module names
- Download filenames based on module names (`<module_name>_draft.v` and `<module_name>.v`)
- Automatic timescale extraction from testbench and application to generated code

### Timescale Handling

The system automatically:
1. **Extracts** the timescale directive from the uploaded testbench (e.g., `` `timescale 1ns/1ps ``)
2. **Prepends** this timescale to all generated and optimized Verilog code during compilation to ensure consistency and prevent Verilator warnings
3. **Strips** the timescale from downloaded files so users receive clean Verilog without compilation directives

This ensures that Verilator recognizes all modules in the design hierarchy as having compatible timescales, eliminating IEEE 1800-2023 compliance warnings.

## Development & Troubleshooting

### Check Logs

**Backend:**
```bash
docker logs hdlfactory-backend
```

**Worker:**
```bash
docker logs hdlfactory-worker
```

**Ollama:**
```bash
docker logs hdlfactory-ollama
```

### GPU Detection Issues

If the system status shows "GPU: unknown" but you have a GPU installed:
1. Verify GPU device nodes exist: `ls /dev/nvidia* 2>/dev/null || echo "No NVIDIA GPU devices"`
2. Check docker-compose.yml mounts `/dev/dri` correctly
3. Inspect Ollama output for processor hints: `docker logs hdlfactory-ollama | grep -i processor`
4. Try CPU-only mode: set Ollama `OLLAMA_NUM_PARALLEL=1` (slower but works)

### Model Pull Failures

If Ollama fails to download models:
1. Check internet connectivity and Ollama health: `docker logs hdlfactory-ollama`
2. Retry manually:
   ```bash
   docker exec hdlfactory-ollama ollama pull ministral-3:3b
   docker exec hdlfactory-ollama ollama pull codestral:22B
   ```
3. Ensure sufficient disk space (at least 50 GB for both models)

### Job Stuck or Timeout

- Long Verilator compilations can take 1–5 minutes depending on complexity
- Ollama inference can take 2–10 minutes on CPU or 30s–2 min on GPU
- Check worker logs: `docker logs hdlfactory-worker | tail -100`
- If worker crashed, restart: `docker restart hdlfactory-worker`

### Verilog Compilation Errors

- Review detailed logs via the UI (Logs tab) or API (`GET /logs/{job_id}`)
- Stage A logs appear after Step 2; optimized design logs after Step 4
- Icarus Verilog logs appear after Step 5

### Optimization Failures (Step 4)

If the optimized design fails the testbench:
- The system automatically falls back to using Stage A as the final design
- This fallback is **transparent** — users see "Step 4 of 5: Optimized design failed, falling back to Stage A..."
- If Stage A passes (as expected), the job completes successfully
- The final downloadable design (`<module_name>.v`) will be the Stage A version
- This safety mechanism ensures users always receive a working design when possible
- Check `opt_stdout.log` and `opt_stderr.log` in the job directory to see why optimization failed

### Redis Queue Backlog

- If queue depth grows, check worker availability: `docker exec hdlfactory-redis redis-cli llen hdl_jobs`
- Verify worker is running: `docker ps | grep hdlfactory-worker`
- Scale workers by running additional containers (currently single worker)

## Performance Notes

- **GPU:** LLM inference typically 30s–2min per stage (much faster than CPU)
- **CPU:** LLM inference 5–15 minutes per stage (recommended only for testing)
- **Verilator:** Compilation 30s–2min depending on design complexity
- **Disk I/O:** Job artifacts (logs, generated files) typically 1–10 MB per job
- **Memory:** Backend ~200 MB, Worker ~500 MB, Ollama ~8–16 GB (for model cache)

## Security Notes

- CORS is open (`allow_origins=["*"]`) for local development; restrict in production
- No authentication implemented; add if exposing over network
- SQL injection is prevented via parameterized queries
- Model outputs are validated before writing to disk (markdown stripped)

## References

- **Ollama:** https://ollama.ai/
- **Ministral-3 (3B):** https://mistral.ai/
- **Codestral-22B:** https://mistral.ai/technology/codestral/
- **Verilator:** https://www.veripool.org/wiki/verilator
- **Icarus Verilog:** http://iverilog.icarus.com/
- **FastAPI:** https://fastapi.tiangolo.com/
- **Redis:** https://redis.io/

## License

Project developed for UMBC CMPE 641 (Spring 2026).

---

**Questions or Issues?** Check the troubleshooting section above or review logs in the appropriate service container.
