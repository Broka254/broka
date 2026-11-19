// Whether this build makes AI covers (2026-11-19: off for now).
//
// Sellers upload their own cover on the Cover step. The AI half of that
// step - the looks, "Create my cover", the tries left - is out of sight,
// not deleted, and "Zeno lists it for me" no longer offers one; the plans
// stop listing them (PremiumFeature.all). The server refuses them too
// (backend AI_COVERS_ENABLED, api/domains/showcase/service.py), so an older
// build that still offers a cover is told to upload one instead.
//
// To bring them back: switch the server on, then build with
// --dart-define=AI_COVERS_ENABLED=true.
const bool kAiCoversEnabled = bool.fromEnvironment('AI_COVERS_ENABLED', defaultValue: false);
