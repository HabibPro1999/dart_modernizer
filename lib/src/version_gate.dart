import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// Minimum language versions each feature requires to compile.
class FeatureFloors {
  static final Version dotShorthands = Version(3, 10, 0);
  static final Version privateNamedParams = Version(3, 12, 0);
  static final Version primaryConstructors = Version(3, 13, 0);
}

/// SDK reality used to gate features: the package's declared language floor
/// (from `pubspec.yaml`) and the installed toolchain (the running VM).
///
/// The *declared floor* governs what the analyzer permits per library; the
/// *installed* toolchain governs what can actually be compiled/formatted. A
/// feature is usable only when both clear its floor.
class SdkContext {
  /// Lower bound of `environment: sdk:` in the package's pubspec.
  final Version packageFloor;

  /// Version of the Dart toolchain running this tool.
  final Version installed;

  const SdkContext({required this.packageFloor, required this.installed});

  /// Loads the SDK context for the package rooted at [packageRoot].
  static SdkContext load(String packageRoot) {
    final pubspec = File(p.join(packageRoot, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw StateError('No pubspec.yaml at $packageRoot');
    }
    final doc = loadYaml(pubspec.readAsStringSync());
    final sdk = (doc is YamlMap ? doc['environment'] : null) is YamlMap
        ? (doc['environment'] as YamlMap)['sdk']
        : null;
    if (sdk is! String) {
      throw StateError('pubspec.yaml has no environment.sdk constraint');
    }
    return SdkContext(
      packageFloor: _lowerBound(sdk),
      installed: _parseLeadingVersion(Platform.version),
    );
  }

  /// Whether a feature with [floor] is *emittable* right now: the package floor
  /// is high enough AND the installed toolchain understands the syntax.
  FeatureGate gateFor(Version floor) {
    final floorOk = packageFloor >= floor;
    final toolchainOk = installed >= floor;
    return FeatureGate(
      floor: floor,
      packageFloorMet: floorOk,
      toolchainMet: toolchainOk,
    );
  }

  /// Parses the lower bound of a pubspec SDK constraint such as
  /// `">=3.7.0 <4.0.0"` or `"^3.7.0"`.
  static Version _lowerBound(String constraint) {
    final parsed = VersionConstraint.parse(constraint);
    if (parsed is VersionRange && parsed.min != null) return parsed.min!;
    if (parsed is Version) return parsed;
    // Fall back to a permissive floor if we cannot read a lower bound.
    return Version(3, 0, 0);
  }

  /// Extracts the leading `x.y.z` from a `Platform.version` string such as
  /// `"3.11.5 (stable) (...) on \"macos_arm64\""`.
  static Version _parseLeadingVersion(String raw) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(raw.trim());
    if (match == null) return Version(0, 0, 0);
    return Version(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }
}

/// Whether a single feature can be applied given the SDK context.
class FeatureGate {
  final Version floor;
  final bool packageFloorMet;
  final bool toolchainMet;

  const FeatureGate({
    required this.floor,
    required this.packageFloorMet,
    required this.toolchainMet,
  });

  /// Safe to emit only when both walls clear.
  bool get usable => packageFloorMet && toolchainMet;

  /// Human-readable reason the feature is blocked, or null if usable.
  String? blockedReason() {
    if (usable) return null;
    final parts = <String>[];
    if (!packageFloorMet) {
      parts.add('pubspec sdk floor must be raised to >=$floor');
    }
    if (!toolchainMet) {
      parts.add('installed Dart toolchain must be upgraded to >=$floor');
    }
    return parts.join('; ');
  }
}
