Act as a Principal Research Engineer and MATLAB Expert. Implement a highly structured, production-grade hybrid optimization system that combines a SMAC-like surrogate pipeline (Sequential Model-based Algorithm Configuration) with the Grey Wolf Optimizer (GWO). This system must optimize a Network Design Problem (e.g., placing wireless sensor nodes to minimize latency and energy while maximizing spatial coverage).

Use idiomatic MATLAB coding standards. Utilize vectorization where appropriate to ensure high performance, and structure the application cleanly using distinct files or a robust class-based architecture.

---

### 1. CODE ARCHITECTURE & FILE STRUCTURE
Ensure the codebase is deeply modular and highly decoupled. Follow this exact directory structure:

├── +network/
│   ├── NetworkEnv.m       # Class/Functions defining the grid, node paths, and multi-objective cost function
├── +optimizer/
│   ├── GWOEngine.m        # Wolf pack state tracking, alpha/beta/delta updates, encircling equations
│   └── SMACSurrogate.m    # Surrogate modeling using fitrgp (Gaussian Process) or custom kriging, acquisition logic
├── utils/
│   └── LogManager.m       # Structured command-line logging utility
├── main.m                 # Main orchestrator script executing the hybrid SMAC-GWO optimization loop
├── simulate.m             # Script/Function handling runtime metrics visualization and final plot rendering
└── README.md              # Comprehensive production documentation and mathematical formulation

---

### 2. STEP-BY-STEP STEPPED VERSION CONTROL PLAN (4 to 5 Commits)
Execute this coding assignment incrementally. Do not generate all code in one massive output block. Stop after each commit phase, display the code files created/modified, and simulate a clear git commit message. Do not proceed to the next step until I explicitly instruct you to.

- Commit 1: "feat: establish core network optimization environment and fitness metrics"
  Implement the network grid space. Define the objective function calculating Latency, Node Energy Consumption, and Area Coverage based on node coordinate vectors.
- Commit 2: "feat: implement standard Grey Wolf Optimizer (GWO) vector mechanics"
  Implement wolf initialization, fitness sorting, and the mathematical position updates tracking the Alpha (α), Beta (β), and Delta (δ) wolves.
- Commit 3: "feat: integrate SMAC Gaussian Process surrogate and acquisition loop"
  Build the surrogate layer using MATLAB’s `fitrgp` (or a lightweight regression equivalent). Implement an acquisition function (e.g., Expected Improvement or lower confidence bound) to screen candidate wolf movements before full simulation evaluation.
- Commit 4: "feat: bridge SMAC-GWO into a unified optimization pipeline"
  Interlock the components so GWO dynamically queries the SMAC surrogate to evaluate candidate positions, saving heavy computation and helping the pack escape local minima.
- Commit 5: "chore: implement unified logging, real-time visualizer, and README documentation"
  Build out the live-updating figure charts, structured command window logging, and the comprehensive README file.

---

### 3. QUALITY, STYLE & VISUALIZATION REQUIREMENTS
- Coding Style: Provide clear comments describing the algorithmic transition steps. Use meaningful variable names (e.g., `alpha_pos`, `wolf_fitness`) and avoid hardcoded magic numbers.
- Logging: Use the command window to print clean, tabular updates per iteration showing: [Iteration | Best Alpha Fitness | Surrogate Root MSE | Search Diversity Index].
- MATLAB Visuals & Plots: In `simulate.m`, generate a dual-panel figure (`subplot(1,2,1)` and `subplot(1,2,2)`):
  1. Convergence Curve: A live-updating plot charting fitness scores over iterations, showcasing the speedup of SMAC-GWO vs an ordinary optimization baseline.
  2. Network Layout Grid: A 2D spatial scatter plot visualizing the final Alpha wolf's optimal node coordinates, their transmission radii (`viscircles`), and active communication routing paths.
- README.md: Include deployment details, toolbox dependencies (e.g., Statistics and Machine Learning Toolbox), and mathematical definitions of the hunting and surrogate validation loops.

Acknowledge this prompt and present the code for Commit 1 to begin.