The initial freeze command stopped before writing a source manifest because it
referenced a nonexistent `src/quod_physics_geometry.erl`. No review was invoked.
The actual native geometry parser is `native/quod_physics/src/geometry.rs`.
Preparation continues in this uninvoked directory with that corrected input;
the manifest is written only after all inputs are captured.
