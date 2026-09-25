/// Same states as Windows Zarp's `EngineState` (`Core/Engine.cs`).
public enum EngineState: Sendable, Equatable {
    case idle
    case preparing
    case searching
    case connecting
    case connected
    case disconnecting
}
