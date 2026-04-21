import Foundation

extension Airpdf_V1_SyncEnvelope {
    static func wrap(_ payload: Airpdf_V1_Payload.OneOf_Body) -> Airpdf_V1_SyncEnvelope {
        var env = Airpdf_V1_SyncEnvelope()
        env.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        env.payload.body = payload
        return env
    }
}
