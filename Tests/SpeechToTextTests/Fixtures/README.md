# Test Fixtures

JSON + text fixtures shipped with the test bundle via `Package.swift`
(`resources: [.copy("Fixtures")]`) and loaded via `HTTPStubFixture.load(_:)`.

## Layout

```
Fixtures/
  cliniko/
    requests/<endpoint>.json     # expected outgoing payloads (golden checks)
    responses/<endpoint>.json    # stub responses returned by URLProtocolStub
  soap/
    valid/<case>.json            # valid SOAP JSON the LLM should emit
    invalid/<case>.json          # edge cases the schema guard must reject
  llm/
    prompts/<case>.txt
    expected/<case>.json         # golden output (used only when RUN_MLX_GOLDEN=1)
```

## Naming

Use `snake_case` that matches the endpoint, e.g. `user.json`,
`patients_search.json`. For variants of the same endpoint, add a suffix:
`patients_search_empty.json`, `patients_search_paginated.json`.

## When to add a fixture vs inline the data

- **Add a fixture** when the payload is more than ~10 lines or the same shape
  is reused across tests.
- **Inline** small one-off payloads so the test narrative stays readable.

## Updating fixtures

Fixtures are code. Commit changes with a PR that explains **why** the shape
changed (e.g. Cliniko API version bump, new field added, schema tightened).
Do not auto-regenerate from production data — fixtures must never contain PHI.
