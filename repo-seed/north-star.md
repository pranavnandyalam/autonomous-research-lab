# North Star

> Written by {{OWNER_NAME}}. The agent reads this every cycle and must never edit it.
>
> **These are YOUR goals: change anything.** This starting version aims the lab at novel research on
> what is happening in AI right now. To point it somewhere else (a topic, replications only, a tool you want
> built), edit this file on github.com or run `./goals.sh edit` on your Mac. The agent picks up the change at
> the start of its next cycle. Keep the "Hard limits" section unless you know why you are removing it.

## What this lab is
An always-on lab that tracks what is happening in AI *right now*, finds the open questions inside the
biggest current developments, and turns the best ones into small, finished, rigorous projects that add
something new. Discovery is half the job: the lab should always be actively scouting for the next thing
worth a project.

## Goals
1. Stay on the frontier: every project connects to something the field is actively discussing this month
   (new models, papers, methods, benchmarks, debates).
2. **Aim for novelty.** Every project must contribute something nobody has done: a new method or variant,
   a new finding or explanation, a new analysis, benchmark, or tool. Replicating a claim is a step (a
   baseline to build on), never the whole project. A sharp negative result counts only if it is new.
3. Produce work I could extend into a workshop paper.
4. Every project ends with a write-up I can read in 10 minutes.

## Novelty bar (applies to every PLAN.md)
- Start PLAN.md with "What's new here", one or two sentences: the contribution nobody has made yet.
- Back it with a literature check (arXiv, Semantic Scholar, GitHub): list the closest prior work and say how
  this differs. The overseer verifies this before approving; "nobody has replicated X" alone is not enough.
- Prefer ideas the lab can own: a new variant of a hot method, combining two recent ideas, explaining *why*
  something works, a cheaper approximation, or a new evaluation that exposes a failure nobody measured.
- Keep it CPU-sized: a small, sharp new result beats an ambitious one that cannot finish.

## Standing scouting mandate (always on)
- Keep `radar.md` current: the top ~10 things happening in AI right now. Each entry: 2+ sources (arXiv,
  Hugging Face papers/trending, Hacker News, Semantic Scholar, GitHub), date seen, why it matters, and a
  CPU-feasible project angle. Refresh at least daily; drop stale items.
- Promote the best radar items into `backlog.md`, scored: novelty (weighted highest) × trend importance ×
  CPU feasibility × chance of a finished write-up. For each item, write the original angle, not just the paper.
- When something big drops, re-rank and start a new project on it (new folder `projects/<slug>/` with its
  own PLAN.md), within the 2-active-project limit and with overseer approval.

## Lenses I care about (for picking angles, not limits; replace with yours)
- e.g. Reasoning, prompting, preference optimization
- e.g. Agents and tool use, and how they fail
- e.g. Small/open models and efficiency
- e.g. Evaluation, benchmarks, contamination, reproducibility

## Hard limits
- CPU only (no GPU in the sandbox): find the small-scale angle of big ideas; skip what needs a GPU or a paid API.
- Health or finance topics: public de-identified or historical data only, never medical advice or live
  trading; ask me in questions.md first.
- The ethics section of your manual, and anything the ethics reviewer rejects.

## What "done" looks like
README with: one-line takeaway on top (negative results count), what is new, which trend it responds to,
abstract, method, results table (>=3 seeds, mean ± spread), fair baselines, limitations, reproduction steps,
AI-authorship note. Runs end-to-end on CPU in hours.

## Current priorities (edit any time)
- First: build `radar.md` from a fresh sweep of the last ~2 weeks of AI papers and news.
- Then pick the radar item with the best original angle and finish one small, novel project end-to-end.
- Keep >=10 sourced, novelty-scored candidates in `backlog.md`.
