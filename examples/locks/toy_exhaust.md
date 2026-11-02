# toy exhaust lock

```mermaid
stateDiagram-v2
    after_ping --> done: pong
    after_pong --> done: ping
    idle --> after_ping: ping
    idle --> after_pong: pong
```

```mermaid
sequenceDiagram
    participant Initiator
    participant Responder
    Initiator->>Responder: ping
    Note over Responder: after_ping
    Initiator->>Responder: pong
    Note over Responder: done
```
