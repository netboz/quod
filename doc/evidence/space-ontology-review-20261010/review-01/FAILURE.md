# Review 01 launch failure

The sandboxed launcher exited 1 while collecting `git rev-parse HEAD` through
Node `execFileSync`: `Error: spawnSync git EPERM` at run-review.mjs:47.
The child output contained commit `4ba646223870c4706f3c2ca0de4b84c76e4d2a92`,
but the subprocess API reported failure. The source copies and request had
already been frozen in `tree/`; no manifest or Fable process was started.
This attempt is retained and is not a completed review. The separately labelled
review-02 requests the external execution permission needed for the consultation.
