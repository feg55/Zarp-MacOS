import NetworkExtension

// System extensions are separate processes, not App Extensions hosted by a shared XPC service —
// this call is what makes the process start acting as the provider(s) declared in Info.plist's
// NetworkExtension/NEProviderClasses, per NEProvider.h's own doc comment.
NEProvider.startSystemExtensionMode()

dispatchMain()
