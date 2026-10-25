# SMAC-GWO: Surrogate-Assisted Grey Wolf Optimisation for Sensor Network Design

A MATLAB hybrid optimiser that places wireless sensor nodes to **minimise latency and energy while maximising coverage**. A Grey Wolf Optimizer (GWO) explores the layout space. A SMAC-style Gaussian Process surrogate decides which candidate layouts are worth running through the network simulation.

With the default settings (20 nodes, 30 wolves, seed 42), the hybrid reaches a fitness of **0.159** after about 615 real evaluations. Plain GWO reaches **0.212** with the same budget. Lower is better.

---

## 1. Requirements

| Requirement | Why | Required? |
|---|---|---|
| MATLAB **R2021a** or newer (tested on R2025b) | `arguments` blocks, implicit expansion, `animatedline`, `exportgraphics`, `subtitle` | Yes |
| **Statistics and Machine Learning Toolbox** | `fitrgp` (Gaussian Process surrogate) | Yes |
| Image Processing Toolbox | `viscircles` for the transmission radii | No (plain line circles are drawn without it) |

To check that the required toolbox is installed:

```matlab
license('test', 'Statistics_Toolbox')   % 1 = your license covers it
which fitrgp                            % must print a path, not "not found"
```

If the license test returns 1 but `fitrgp` is not found, install the toolbox from **Home → Add-Ons → Get Add-Ons**.

---

## 2. Quick start

From the project root, run:

```matlab
results = simulate();                        % run both optimisers with a live figure
results = main();                            % same runs, command window output only
results = simulate('SavePath', 'run.png');   % also save the figure as an image
results = main('NumNodes', 30, 'MaxIterations', 100, 'Seed', 7);
```

`main` options (name-value):

| Option | Default | Meaning |
|---|---|---|
| `NumNodes` | 20 | Sensor nodes N (search dimension D = 2N) |
| `NumWolves` | 30 | Pack size |
| `MaxIterations` | 60 | Hybrid GWO iterations |
| `NumProposals` | 8 | Candidate moves generated per wolf per iteration |
| `EvalFraction` | 0.3 | Share of the pack that gets a real evaluation each iteration |
| `StagnationLimit` | 5 | Iterations without improvement before uncertainty-driven exploration |
| `Seed` | 42 | Random seed (the same seed is used for both runs) |
| `RunBaseline` | true | Also run plain GWO with the same evaluation budget |
| `Verbose` | true | Print the iteration table |
| `IterationCallback` | `[]` | `@(progress)` hook called after every iteration |

`results` contains `env`, `hybrid`, `baseline` and `options`. Each run struct contains `best_position`, `best_fitness`, `history`, `diversity`, `evaluations` and `num_evaluations`. The hybrid run also contains `surrogate_rmse`.

### Running the tests

```matlab
addpath('tests');
testNetworkEnv; testGWOEngine; testSMACSurrogate; testPipeline; testLogManager;
```

Call the test scripts by name from the project root. Don't use `run('tests/...')`: it switches into `tests/` first, so the scripts' `addpath(pwd)` points to the wrong folder.

---

## 3. Project layout

```
├── +network/
│   └── NetworkEnv.m       WSN field, routing, energy/latency/coverage, scalar fitness
├── +optimizer/
│   ├── GWOEngine.m        Wolf pack state, alpha/beta/delta, encircling + hunting
│   └── SMACSurrogate.m    fitrgp surrogate, EI / LCB acquisition, validation RMSE
├── utils/
│   └── LogManager.m       Command-window table logging
├── tests/                 Script-based tests, one per component
├── main.m                 Hybrid SMAC-GWO loop + plain GWO baseline
├── simulate.m             Live dual-panel figure
└── README.md
```

The components are decoupled. `GWOEngine` only proposes positions and accepts fitness values: `initializePack`, `proposeCandidates`, `receiveFitness`. It knows nothing about networks or surrogates. `main.m` is the only place where the parts are connected.

---

## 4. Mathematical formulation

### 4.1 Network design problem

**Decision vector:** x = [x₁ … x_N, y₁ … y_N] ∈ [0, W]^N × [0, H]^N. Each pair (xᵢ, yᵢ) is the position of one sensor node. A fixed sink sits at the centre of the field by default.

**Routing:** two nodes are linked when they are at most `CommRadius` (R_c) apart. The cost of a link is d². Each node routes to the sink along the shortest path (Dijkstra), which gives the minimum-energy multi-hop route.

**Objectives**, each normalised to roughly [0, 1]:

- **Latency.** Mean hop count to the sink, divided by N:
  L = (1/N) Σᵢ hᵢ / N. A disconnected node counts as hᵢ = N.
- **Energy.** Uses the first-order radio model (Heinzelman et al.) for one reporting round. For each hop a→b on a route:
  - the sender pays E_tx = k (E_elec + ε_amp d²);
  - the receiver pays E_rx = k E_elec.

  The score is the energy of the busiest node (a proxy for network lifetime), divided by a worst-case bound:
  E = maxᵢ eᵢ / E_worst.
- **Coverage.** The fraction C of grid sample points that lie within `SensingRadius` of at least one node.

**Scalar fitness** (minimised):

```
f(x) = w_L · L + w_E · E + w_C · (1 − C) + P · (1 − connectivity)
```

The default weights are w = [0.25, 0.25, 0.50]. The disconnection penalty is P = 1.

### 4.2 Grey Wolf Optimizer: the hunting loop

The three best positions found so far lead the pack: **α**, **β** and **δ**. Every wolf X moves under the influence of each leader X_ℓ ∈ {α, β, δ}:

```
A  = 2a·r₁ − a,      C = 2·r₂               r₁, r₂ ~ U(0,1) per coordinate
D_ℓ = | C ⊙ X_ℓ − X |                       encircling: distance to leader ℓ
X_ℓ' = X_ℓ − A ⊙ D_ℓ                        move suggested by leader ℓ
X(t+1) = clip( (X_α' + X_β' + X_δ') / 3,  lb, ub )
```

The control parameter falls linearly, a(t) = 2 (1 − t / T):

- while |A| > 1, wolves move away from the leaders (exploration);
- once |A| < 1, they close in on them (exploitation).

The leaders are **elitist**: they are re-selected each iteration from the old leaders plus the newly evaluated wolves, so the best fitness never gets worse. The update is fully vectorised over wolves and dimensions.

**Search Diversity Index:** the mean distance of the wolves from the pack centroid, divided by the length of the search-space diagonal. It is about 0.3 for a random pack and approaches 0 when the pack has collapsed onto one point.

### 4.3 SMAC surrogate

Every real evaluation (x, f(x)) goes into a training set. Before fitting:

- inputs are scaled to [0, 1]^D;
- targets are standardised to z-scores.

A Gaussian Process is then fitted with `fitrgp`. It uses a Matérn 5/2 kernel and a constant basis, and its hyper-parameters are chosen by maximising the marginal likelihood. The GP gives a predicted mean μ(x) and an uncertainty σ(x).

For stability, the noise lower bound starts at 10⁻³ and is raised to 10⁻² and then 10⁻¹ if the Cholesky factorisation fails.

The training set holds at most 300 points, because GP fitting costs O(n³). When it is full, it keeps:

- the best 20% of points (elites), so the model stays accurate near the optimum;
- the most recent points, so it stays accurate where the pack is searching now.

**Acquisition: Expected Improvement** (default). Here f* is the best fitness observed so far:

```
I(x)  = f* − μ(x) − ξ
z     = I(x) / σ(x)
EI(x) = I(x) · Φ(z) + σ(x) · φ(z)
```

The alternative is the Lower Confidence Bound, with score −(μ − κσ) and κ = 2.

### 4.4 Hybrid loop and surrogate validation

For each iteration t:

1. **Propose.** GWO makes K = `NumProposals` independent random moves for each wolf, giving K·n candidates. The pack moves once per iteration.
2. **Screen.** Every candidate is scored with EI. Each wolf keeps its best-scoring proposal.
3. **Evaluate selectively.** Only the top ⌈ρ·n⌉ wolves by EI are run through the network simulation, where ρ = `EvalFraction`. The other wolves move with fitness μ(x) and are flagged as *predicted*. Predicted wolves can never become α, β or δ, so a wrong GP prediction cannot mislead the pack.
4. **Validate, then learn.** The surrogate's error is measured on the freshly evaluated points *before* it is trained on them:
   `RMSE_t = sqrt( mean( (μ(xᵢ) − f(xᵢ))² ) )`
   Because the model hasn't seen these points, this is an honest out-of-sample error. Afterwards the points are added to the training set and the GP is refitted.
5. **Escape stagnation.** If α has not improved for `StagnationLimit` iterations, another ⌈ρ·n⌉ wolves are evaluated. These are the ones with the **largest σ**, where the model knows least. This pushes the pack into unexplored regions instead of letting it keep refining a local minimum.

The **baseline** is plain GWO with the same number of real evaluations, so the convergence curves are compared at equal simulation cost.

---

## 5. Output

### Command window

```
== Hybrid SMAC-GWO ==
+-----------+----------------------+------------------+-------------------+---------+
| Iteration | Best Alpha Fitness   | Surrogate RMSE   | Diversity Index   | Evals   |
+-----------+----------------------+------------------+-------------------+---------+
|         0 |             0.279713 |                - |            0.2891 |      30 |
|         1 |             0.279713 |          0.15292 |            0.2476 |      39 |
[20:25:09] INFO Stagnation at iteration 9: also evaluating the 9 most uncertain wolves
...
```

### Figure (`simulate.m`)

- **Left panel, convergence.** The best α fitness of each run is plotted against the number of real network evaluations, updating live. Both runs share one x-axis, so a curve that drops further to the left reached that fitness with fewer simulations. Each curve is labelled with its final value.
- **Right panel, network layout.** Shows the final α layout:
  - sensor nodes (hollow markers mark disconnected nodes);
  - the sink;
  - dotted transmission-radius circles;
  - the routes to the sink.

  The subtitle shows coverage, mean latency and connectivity.

---

## 6. Deployment notes

- **Reproducibility.** Both runs reseed with `rng(Seed)`, so results can be repeated on the same MATLAB version. The GP hyper-parameter optimiser can differ slightly between releases.
- **Headless or CI runs.** Use `matlab -batch "simulate('Visible', false, 'SavePath', 'run.png')"`. The figure is rendered off-screen and saved.
- **Runtime.** Most of the time per iteration goes into `fitrgp`, which grows with the training-set size (capped at 300 points) and with D = 2N. The default problem runs in about 10 s on a laptop. For bigger networks, lower `MaxTrainingSize` in `SMACSurrogate` or raise `EvalFraction`.
- **Tuning.** A higher `EvalFraction` trusts the surrogate less and spends more evaluations. A higher `NumProposals` gives the surrogate more candidates to screen, at almost no extra cost.
- **Other problems.** `GWOEngine` and `SMACSurrogate` work with any box-bounded objective `f: (n × D) → (n × 1)`. Replace `env.evaluatePopulation` in `main.m` with your own function.

## 7. References

- S. Mirjalili, S. M. Mirjalili, A. Lewis. *Grey Wolf Optimizer.* Advances in Engineering Software, 69, 2014.
- F. Hutter, H. H. Hoos, K. Leyton-Brown. *Sequential Model-Based Optimization for General Algorithm Configuration.* LION 5, 2011.
- D. R. Jones, M. Schonlau, W. J. Welch. *Efficient Global Optimization of Expensive Black-Box Functions.* J. Global Optimization, 13, 1998.
- W. B. Heinzelman, A. P. Chandrakasan, H. Balakrishnan. *An Application-Specific Protocol Architecture for Wireless Microsensor Networks.* IEEE Trans. Wireless Communications, 1(4), 2002.
