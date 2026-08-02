const std = @import("std");
const cpa_management = @import("codex_auth").api.cpa_management;

test "CPA key payload appends a new key and preserves advanced fields" {
    const allocator = std.testing.allocator;
    const response =
        \\{"codex-api-key":[{"api-key":"existing","base-url":"https://existing.example/v1","priority":4,"headers":{"X-Test":"yes"},"auth-index":"runtime-only"}]}
    ;
    const payload = try cpa_management.buildCodexApiKeyPayloadAlloc(
        allocator,
        response,
        "sk-new",
        "https://relay.example.com/v1",
        true,
    );
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\"priority\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"X-Test\":\"yes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "auth-index") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"api-key\":\"sk-new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"base-url\":\"https://relay.example.com/v1\"") != null);
}

test "CPA key payload removes only the matching key and base URL" {
    const allocator = std.testing.allocator;
    const response =
        \\{"codex-api-key":[{"api-key":"same","base-url":"https://one.example/v1"},{"api-key":"same","base-url":"https://two.example/v1","weight":3}]}
    ;
    const payload = try cpa_management.buildCodexApiKeyPayloadAlloc(
        allocator,
        response,
        "same",
        "https://one.example/v1",
        false,
    );
    defer allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "https://one.example/v1") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "https://two.example/v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"weight\":3") != null);
}

test "CPA key payload treats a null list as an empty pool" {
    const allocator = std.testing.allocator;
    const payload = try cpa_management.buildCodexApiKeyPayloadAlloc(
        allocator,
        "{\"codex-api-key\":null}",
        "sk-first",
        "https://api.openai.com/v1",
        true,
    );
    defer allocator.free(payload);

    try std.testing.expectEqualStrings(
        "[{\"api-key\":\"sk-first\",\"base-url\":\"https://api.openai.com/v1\"}]",
        payload,
    );
}
