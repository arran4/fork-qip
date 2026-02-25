(module
  (import "impl" "memory" (memory 1))
  (import "impl" "run" (func $run (param i32) (result i32)))

  ;; Returns >0 on pass, <=0 on failure.
  ;; Check: empty input must not trap, and output size should be stable.
  (func (export "positive") (result i32)
    (local $first i32)
    (local $second i32)

    (local.set $first (call $run (i32.const 0)))
    (local.set $second (call $run (i32.const 0)))

    (if (i32.ne (local.get $first) (local.get $second))
      (then
        (return (i32.const -1))
      )
    )

    ;; 2 checks passed: first call succeeded, second call matched.
    (i32.const 2)
  )
)
