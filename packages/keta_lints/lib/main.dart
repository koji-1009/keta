/// The keta_lints analyzer plugin entry point.
///
/// The analysis server imports this file and reads the top-level [plugin]
/// variable. Enable it from a consuming package's `analysis_options.yaml`:
///
/// ```yaml
/// plugins:
///   keta_lints: ^0.1.0
///   # or, within this workspace / for local development:
///   #   keta_lints:
///   #     path: ../keta_lints
///   # keta_internal_await is a lint (framework-development only); opt in with:
///   #     diagnostics:
///   #       keta_internal_await: true
/// ```
///
/// The five route/query/canonical/tx/key rules are warnings — enabled by
/// default once the plugin is on. They surface the same ids and messages as
/// `dart run keta_lints:check`. Cross-file checks (route conflicts, contract
/// drift) remain CLI-authoritative and are not part of the plugin.
library;

import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/plugin/rules.dart';

/// The plugin instance the analysis server loads.
final plugin = KetaPlugin();

class KetaPlugin extends Plugin {
  @override
  String get name => 'keta_lints';

  @override
  void register(PluginRegistry registry) {
    // Enabled by default (analyzer "warnings").
    registry.registerWarningRule(KetaRouteRule());
    registry.registerWarningRule(KetaQueryRule());
    registry.registerWarningRule(KetaCanonicalRule());
    registry.registerWarningRule(KetaTxOrderRule());
    registry.registerWarningRule(KetaKeyRule());
    // Opt-in (analyzer "lint"): only meaningful over keta's own source.
    registry.registerLintRule(KetaInternalAwaitRule());
  }
}
