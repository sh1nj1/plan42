# T4/T5 original preservation

Source: /tmp/plan42-worktree3
Original SHA: 5b945fdad7498f350c787a6ee11ece8d46d256c5
Remote branch: preserve/t4-t5-original-20260908

This branch preserves artifacts without applying the implementation to its source tree. No reimplementation or source checkout modification was performed.

T4-T5-original.patch matches git format-patch of the original combined T4/T5 commit byte for byte. prerequisite-history.patch preserves preceding changes. T4-T5-history.bundle preserves the original commit SHAs; its internal ref is refs/heads/preserve/t5-original-20260908 and required prerequisite is 5ca92af7c0cf27eecd9e8229ae36630ae43fb910.

original-untracked-dependencies.tar.gz contains envelope.js, hit_test.js and session.js, uncommitted T1 dependencies used by the historical tests. The commit alone is not the complete tested checkout.

Historical results: 42 suites / 770 tests passed, additional 2 suites / 30 tests passed. Original earlier failures are retained in original-test-results.log. Tests were not rerun. No T5 completeness claim is made.

Recover in a separate checkout containing the prerequisite:

```sh
git fetch /absolute/path/T4-T5-history.bundle refs/heads/preserve/t5-original-20260908:refs/heads/recovered-t4-t5
git worktree add ../recovered-t4-t5 recovered-t4-t5
tar -xzf /absolute/path/original-untracked-dependencies.tar.gz -C ../recovered-t4-t5
```
