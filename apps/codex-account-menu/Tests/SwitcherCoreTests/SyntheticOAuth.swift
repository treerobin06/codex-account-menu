import Foundation

/// Structurally valid test JWTs only. These are unsigned fixture data and never
/// leave temporary test homes or authenticate against a real service.
func syntheticIDToken(email: String?, accountID: String, tag: String = "fixture") -> String {
    var claims: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_account_id": accountID], "jti": tag]
    if let email { claims["email"] = email }
    let data = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(payload).fixture"
}

func syntheticOAuthCredential(accountID: String, email: String?, tag: String = "fixture") -> Data {
    try! JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
        "tokens": ["account_id": accountID, "id_token": syntheticIDToken(email: email, accountID: accountID, tag: tag),
                   "access_token": "synthetic-access-\(tag)", "refresh_token": "synthetic-refresh-\(tag)"]], options: [.sortedKeys])
}
