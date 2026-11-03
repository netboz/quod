# Fixture preparation failure, before writes

The first inline preparation attempt raised `AssertionError` at line5 because a preserved comment still contained `base64url`, while the intended assertion checked for any occurrence of that string. It failed before writing any source. The shell command nevertheless continued to launch `applied-build04` with the old build driver/fixture inputs; its saved snapshot and receipt identify those actual inputs. It is not a debug-info-corrected build. The inline child's own exit was not captured separately; no true-exit claim is made for it. Literal tool output:

```
Traceback (most recent call last):
  File "<stdin>", line 5, in <module>
AssertionError
```

`correct-history-fixtures.py` separately corrects the stale comment and performs the intended changes. No runtime operation was replayed and no failed log was overwritten.
