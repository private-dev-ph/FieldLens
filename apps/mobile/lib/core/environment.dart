/// Build-time settings that are safe to include in the application bundle.
///
/// The demo dataset is enabled by default so the application can be explored
/// without Supabase credentials or a running backend.
class AppEnvironment {
  const AppEnvironment._();

  static const bool demoEnabled = bool.fromEnvironment(
    'FIELDLENS_DEMO',
    defaultValue: true,
  );

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabasePublicKey = String.fromEnvironment(
    'SUPABASE_PUBLIC_KEY',
  );

  static bool get hasSupabaseConfiguration =>
      supabaseUrl.isNotEmpty && supabasePublicKey.isNotEmpty;
}
