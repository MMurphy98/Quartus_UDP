---
description: "Explain selected HDL/Verilog logic with signal- and timing-level detail"
name: "Explain HDL Block"
argument-hint: "goal=<what you want to understand>; target=<module/file>; depth=<quick|deep>; focus=<optional>"
agent: "agent"
---
Explain the selected HDL code (Verilog/SystemVerilog/VHDL) using the user arguments and local workspace context.

Default behavior:
- Language: English
- Tone: Teaching clarity first, then practical engineering notes
- If `depth` is omitted: use `deep`

Interpret arguments in this shape (best effort):
- `goal=` what the explanation should optimize for (learning, debug, review, integration)
- `target=` module/file/block to prioritize
- `depth=` quick or deep
- `focus=` optional area (state machine, FIFO, CDC, reset, timing, handshakes)

If some arguments are missing, infer reasonably and state assumptions briefly.

Output format:
1. Purpose and high-level behavior (3-6 sentences)
2. Interface map (inputs, outputs, clocks, resets, handshakes)
3. Internal data/control flow in execution order
4. Timing view: what happens per clock edge and on reset
5. Risks and gotchas: CDC, reset polarity/strategy, width mismatches, blocking vs non-blocking, latch risk, overflow/underflow
6. Practical validation ideas: focused simulation checks, corner cases, and optional assertion ideas

Rules:
- Use exact signal/module names from the code.
- Keep explanations concrete; avoid generic HDL textbook text.
- If context is insufficient, ask up to 3 precise follow-up questions.
- Prefer concise output for `depth=quick`; provide richer step-by-step detail for `depth=deep`.
