//
//  PluginBundleVersionGate.swift
//  TablePro
//

import Foundation

/// Decides whether a plugin bundle's declared framework versions are loadable.
///
/// Split out of `PluginManager` so the decision can be exercised against a
/// synthesized info dictionary instead of a real bundle on disk. This gate is
/// what keeps a stale plugin a clean error rather than an `EXC_BAD_INSTRUCTION`
/// once the app's PluginKit ABI moves, so it needs direct test coverage.
struct PluginBundleVersionGate {
    let currentPluginKit: Int
    let minimumCompatiblePluginKit: Int
    let currentInspectorKit: Int

    func validate(
        declaredPluginKit: Int?,
        declaredInspectorKit: Int?,
        minimumAppVersion: String?,
        appVersion: @autoclosure () -> String
    ) throws {
        if declaredPluginKit == nil, declaredInspectorKit == nil {
            throw PluginError.pluginOutdated(pluginVersion: 0, requiredVersion: currentPluginKit)
        }

        if let version = declaredPluginKit {
            if version > currentPluginKit {
                throw PluginError.incompatibleVersion(required: version, current: currentPluginKit)
            }
            if version < minimumCompatiblePluginKit {
                throw PluginError.pluginOutdated(pluginVersion: version, requiredVersion: currentPluginKit)
            }
        }

        if let version = declaredInspectorKit {
            if version > currentInspectorKit {
                throw PluginError.incompatibleVersion(required: version, current: currentInspectorKit)
            }
            if version < currentInspectorKit {
                throw PluginError.pluginOutdated(pluginVersion: version, requiredVersion: currentInspectorKit)
            }
        }

        if let minimumAppVersion {
            let current = appVersion()
            if current.compare(minimumAppVersion, options: .numeric) == .orderedAscending {
                throw PluginError.appVersionTooOld(minimumRequired: minimumAppVersion, currentApp: current)
            }
        }
    }
}
