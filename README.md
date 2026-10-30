# S-MAC with GWO: Tuning Sensor-MAC with the Grey Wolf Optimizer

In this project, **SMAC means S-MAC (Sensor-MAC)**, the energy-efficient MAC protocol for wireless sensor networks by Ye, Heidemann & Estrin (2002). It does not mean "Sequential Model-based Algorithm Configuration".

S-MAC saves energy by letting nodes sleep on a periodic listen/sleep schedule. Its fixed settings (duty cycle, frame length, contention window, SYNC period) trade energy against delay and reliability, and a single default rarely suits every network. This project uses the **Grey Wolf Optimizer (GWO)** to search for the S-MAC settings that balance:
- **energy**: mean node power and network lifetime;
- **end-to-end delay**;
- **packet delivery ratio (PDR)**.

Every candidate setting is scored by simulating S-MAC on a fixed sensor network.

**Result (20 nodes, seed 42, 1,230 simulations).** GWO-tuned S-MAC cuts the mean delay from **6.14 s to 0.99 s** (6.2× lower) compared with default S-MAC. It keeps a **99.5% PDR** and uses **9% more power**: 1.62 vs 1.48 mW, or 62 vs 67 days of lifetime. Its overall fitness is **0.0678**, against **0.2170** for default S-MAC and **0.0704** for random search with the same budget.

---

## 1. Requirements

| Requirement | Why | Required? |
|---|---|---|
| MATLAB **R2021a** or newer (tested on R2025b) | `arguments` blocks, `RandStream`, `graph`/`shortestpath`, `animatedline`, `exportgraphics`, `subtitle` | Yes |
| Image Processing Toolbox | `viscircles` for the transmission radii | No (plain line circles are drawn without it) |

No other toolboxes are needed. (The earlier surrogate version needed the Statistics and Machine Learning Toolbox; this one doesn't.)

---

## 2. Quick start

From the project root:

```matlab
results = simulate();                                   % GWO + baselines with a live figure (~3 min)
results = main();                                       % same, command window only
results = simulate('SavePath', 'results/run.png');      % also save the figure
results = main('MaxIterations', 20, 'Seed', 7);         % shorter run, other seed
addpath('utils'); make_results_table(results);          % comparison table -> results/results_table.png
```

`main` options (name-value):

| Option | Default | Meaning |
|---|---|---|
| `NumNodes` | 20 | Sensor nodes in the network |
| `NumWolves` | 30 | GWO pack size (and random-search batch size) |
| `MaxIterations` | 40 | GWO iterations, giving 30 × 41 = 1,230 S-MAC simulations |
| `Seed` | 42 | Seed of the optimiser's random numbers |
| `RunBaselines` | true | Also evaluate default S-MAC and run random search |
| `Verbose` | true | Print the iteration tables |
| `IterationCallback` | `[]` | `@(progress)` hook called after every iteration |

`results` contains:
- `env` and `mac`: the network and the simulator;
- `gwo`, `random_search` and `default`: one entry per run, each with the best parameters, its fitness, the full `best_metrics`, and the convergence `history`;
- `options`.

To simulate a single S-MAC setting by hand:

```matlab
env = network.NetworkEnv();
mac = network.SMACProtocol(env);
[fitness, m] = mac.evaluate([0.10 1.0 32 10]);   % [duty, frame (s), CW (slots), SYNC period (frames)]
m.pdr, m.mean_delay, m.mean_power, m.lifetime_days
```

### Running the tests

```matlab
addpath('tests');
testNetworkEnv; testSMACProtocol; testGWOEngine; testLogManager;
```

Call the test scripts by name from the project root. Don't use `run('tests/...')`: it switches into `tests/` first, so the scripts' `addpath(pwd)` points to the wrong folder.

---

## 3. Project layout

```
├── +network/
│   ├── NetworkEnv.m          Fixed WSN: deployment, routing, Poisson traffic, radio power model
│   └── SMACProtocol.m        Frame-level S-MAC simulator + fitness function
├── +optimizer/
│   └── GWOEngine.m           Wolf pack, alpha/beta/delta, encircling + hunting updates
├── utils/
│   ├── LogManager.m          Command-window table logging
│   └── make_results_table.m  Renders the comparison table as a PNG
├── tests/                    Script-based tests, one per component
├── main.m                    GWO tuning loop + default S-MAC and random-search baselines
├── simulate.m                Live dual-panel figure
└── README.md
```

`results/` holds generated figures and tables. It's in `.gitignore`, so it is never committed.

The components are decoupled:
- `GWOEngine` knows nothing about networks. It only proposes positions and receives fitness values.
- `SMACProtocol` knows nothing about GWO.
- `main.m` is the only place where the two meet.

---

## 4. Model

### 4.1 Network (`NetworkEnv`)

- **Deployment:** 20 nodes are placed uniformly at random in a 100 m × 100 m field, with the sink at the centre. The radio range is 30 m. The deployment is re-drawn until every node can reach the sink. With the default seed, routes have 2.85 hops on average and 6 at most.
- **Routing:** each node uses a minimum-energy multi-hop route, found by Dijkstra with link cost d² (transmit energy grows with d²). Each node keeps only its next hop.
- **Traffic:** each node generates packets as a Poisson process with a mean interval of 40 s, for about 0.5 packets/s across the whole network. A run simulates 400 s, and no new packets are generated in the last 30 s so late ones can still arrive. This gives 196 packets.
- **Radio:** Mica2 / CC1000-class values, as in the S-MAC paper:

  | Setting | Value |
  |---|---|
  | Data rate | 20 kbit/s |
  | Tx power | 24.75 mW |
  | Rx / idle power | 13.5 mW |
  | Sleep power | 15 µW |
  | DATA packet | 100 B |
  | RTS / CTS / ACK | 10 B each |
  | SYNC | 9 B |
  | Battery | 10 kJ per node |

**Common random numbers.** The nodes, routes, packets and contention random numbers are identical for every candidate. So two settings are always compared on exactly the same situation, and the fitness of a given x is deterministic.

### 4.2 S-MAC simulator (`SMACProtocol`)

Time is divided into frames of length T. Each frame starts with a listen period L = d·T, where d is the duty cycle; the rest of the frame is sleep.

```
|<----------------------------- frame T ----------------------------->|
| SYNC window | contention + RTS/CTS | DATA/ACK (pair only)   sleep ... |
|<--------- listen L = d·T --------->|
```

Each frame is simulated in the following order:

1. **Queueing.** New packets join their node's queue, which holds up to 10 packets. Packets that arrive at a full queue are dropped.
2. **SYNC.** Every `sync_period` frames, each node broadcasts its schedule.
   - Between SYNCs, two nodes' clocks drift apart at up to 2 × 50 ppm.
   - An exchange misses its receiver with probability p_miss = min(1, ½ · 2·ppm · sync_period · T / L).
3. **Contention.** Each node with a packet picks a random slot in [0, CW − 1]. The slots are 1 ms long.
   - **Carrier sense:** a node defers if a neighbour picked an earlier slot.
   - **Collisions:** an RTS fails if another RTS overlaps it at the receiver. This covers same-slot neighbours and hidden terminals. It also fails if the receiver is transmitting itself (half-duplex).
   - **One exchange per receiver per frame:** if several RTSs reach the same receiver, the earliest wins and the others back off.
   - **Size limit:** the contention window must fit inside the listen period together with SYNC, RTS and CTS; otherwise it is cut short. If nothing fits, no data can be sent.
4. **Exchange.** RTS and CTS happen during the listen period. DATA and ACK follow, with only that pair awake (overhearing avoidance). A packet moves at most one hop per frame, since there is no adaptive listening.
5. **Retries.** A failed attempt is retried in the next frame. After 5 retries the packet is dropped.

Energy per node is accounted as follows:
- listening costs idle power for L every frame;
- sleeping costs sleep power for T − L;
- on top of that come the air times of SYNC, RTS, CTS, DATA and ACK at Tx/Rx power.

The sink is mains powered and not counted.

Network lifetime is the battery energy divided by the power of the busiest node, which is the time until the first node dies.

### 4.3 Decision variables and fitness

GWO searches four continuous values. CW and the SYNC period are rounded to integers when decoded.

| Variable | Range | Default S-MAC |
|---|---|---|
| Duty cycle d | 2% – 50% | 10% |
| Frame length T | 0.2 – 2.0 s | 1.0 s |
| Contention window CW | 4 – 128 slots | 32 |
| SYNC period | 1 – 30 frames | 10 |

Fitness to minimise:

```
f(x) = 0.3 · P_mean / P_idle  +  0.3 · min(delay / 10 s, 1)  +  0.4 · (1 − PDR)
```

- **P_mean / P_idle** is the mean node power relative to a radio that never sleeps.
- **delay** is the mean generation-to-sink time of delivered packets. If nothing is delivered, it counts as the worst value.
- The weights can be changed with `SMACProtocol(env, 'Weights', [w_E w_D w_P])`.

### 4.4 Grey Wolf Optimizer: the hunting loop

The three best settings found so far lead the pack: **α**, **β** and **δ**. Every wolf X (a candidate S-MAC setting) moves under the influence of each leader X_ℓ ∈ {α, β, δ}:

```
A  = 2a·r₁ − a,      C = 2·r₂               r₁, r₂ ~ U(0,1) per coordinate
D_ℓ = | C ⊙ X_ℓ − X |                       encircling: distance to leader ℓ
X_ℓ' = X_ℓ − A ⊙ D_ℓ                        move suggested by leader ℓ
X(t+1) = clip( (X_α' + X_β' + X_δ') / 3,  lb, ub )
```

The control parameter falls linearly, a(t) = 2 (1 − t / T_max):
- while |A| > 1, wolves move away from the leaders (exploration);
- once |A| < 1, they close in on them (exploitation).

The leaders are **elitist**: they are re-selected each iteration from the old leaders plus the new pack, so the best fitness never gets worse. The update is vectorised over all wolves and dimensions.

**Diversity index:** the mean distance of the wolves from the pack centroid, divided by the length of the search-space diagonal. It is about 0.3 for a random pack and approaches 0 when the pack has converged.

### 4.5 Baselines

- **Default S-MAC:** 10% duty cycle, 1 s frame, CW 32, SYNC every 10 frames, simulated once with no tuning.
- **Random search:** uniform random settings in the same bounds, with the **same number of simulations** as GWO (batches of 30). It shows how much of the gain comes from GWO's search strategy rather than from simply trying many settings.

---

## 5. Results (default run)

| | GWO-tuned S-MAC | Default S-MAC | Random search |
|---|---|---|---|
| Duty cycle | 11.0% | 10.0% | 13.9% |
| Frame length | 0.31 s | 1.00 s | 0.27 s |
| Contention window | 99 slots | 32 slots | 78 slots |
| SYNC period | every 18 frames | every 10 frames | every 4 frames |
| **Fitness** (lower is better) | **0.0678** | 0.2170 | 0.0704 |
| Packet delivery ratio | 99.5% | 100.0% | 100.0% |
| Mean end-to-end delay | 0.99 s | 6.14 s | 0.85 s |
| Mean node power | 1.62 mW | 1.48 mW | 2.03 mW |
| Network lifetime | 62 days | 67 days | 51 days |
| RTS collision rate | 6.8% | 11.7% | 6.0% |

**How to read it:**
- **Shorter frames:** GWO shortened the frame from 1 s to 0.31 s. Packets advance one hop per frame, so this is what cuts the delay.
- **Barely more power:** GWO kept the duty cycle near 10%, so power rose only about 9%.
- **Fewer collisions:** a larger contention window halves the collision rate compared with the default.
- **GWO vs random search:** random search found a slightly faster setting (0.85 s) but spends 25% more power than GWO, so its fitness is worse.

The gap between GWO and random search is small (about 4%) because this four-variable space is fairly easy. GWO's advantage should grow with more variables, for example per-cluster schedules.

**Limitations of the model:**
- no adaptive listening (one hop per frame);
- one packet per exchange (no message passing);
- a simplified collision and clock-drift model;
- one deployment and traffic seed.

To generalise the results, repeat them over several `DeploymentSeed`, `TrafficSeed` and `Seed` values.

---

## 6. Output

### Command window

```
== GWO-tuned S-MAC ==
+-----------+--------------+------------+-----------+------+------+-----------+--------+
| Iteration | Best Fitness | Duty Cycle | Frame (s) | CW   | SYNC | Diversity | Evals  |
+-----------+--------------+------------+-----------+------+------+-----------+--------+
...
|        40 |      0.06785 |      11.0% |     0.312 |   99 |   18 |    0.0057 |   1230 |
```

### Figure (`simulate.m`)

- **Left panel, convergence.** The best fitness of GWO and of random search is plotted against the number of S-MAC simulations, updating live. A dashed line marks default S-MAC.
- **Right panel, the sensor network.** Shows the nodes, the sink, the dotted 30 m transmission radii and each node's next-hop route. The subtitle lists the tuned S-MAC parameters and their PDR, delay, power and lifetime.

---

## 7. Deployment notes

- **Reproducibility.** Network, traffic and contention use their own `RandStream` seeds. The optimisers reseed with `rng(Seed)`. The same seeds give identical results.
- **Headless or CI runs.** Use `matlab -batch "simulate('Visible', false, 'SavePath', 'results/run.png')"`.
- **Runtime.** One S-MAC simulation takes about 0.05–0.1 s. The default run is 2 × 1,230 simulations, about 3 minutes. Shorter frames mean more frames to simulate, so they are slower.
- **Tuning the problem.** Change the network and traffic with `NetworkEnv` options (`NumNodes`, `CommRadius`, `PacketInterval`, ...). Change the search bounds and objective weights with `SMACProtocol` options (`LowerBound`, `UpperBound`, `Weights`).

## 8. References

- W. Ye, J. Heidemann, D. Estrin. *An Energy-Efficient MAC Protocol for Wireless Sensor Networks.* IEEE INFOCOM, 2002.
- W. Ye, J. Heidemann, D. Estrin. *Medium Access Control With Coordinated Adaptive Sleeping for Wireless Sensor Networks.* IEEE/ACM Trans. Networking, 12(3), 2004.
- S. Mirjalili, S. M. Mirjalili, A. Lewis. *Grey Wolf Optimizer.* Advances in Engineering Software, 69, 2014.
