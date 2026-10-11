# Release 0.7.258 launcher failure, second campaign

The separately labeled `gates-02` campaign used committed source
`96ab9bf45ae9f3ccebe31a5adc1613d216c3d09d`. Native tests, Clippy, client tests,
UI build and lint passed. The EUnit command then exited 127 before starting:
`env: escript: No such file or directory`.

The launcher had replaced PATH without `/home/yan/.asdf/shims`. This was a
launcher error, with zero EUnit tests executed in the failed step and no source
or network change. The logs and STOP are retained here. The subsequent,
separately labeled `gates-03` campaign keeps the exact same 682 source inputs,
uses the validated tool PATH, and records executable resolution before testing.
This failed campaign is not resumed or counted as a passing release gate.
