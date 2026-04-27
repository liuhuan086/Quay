// ClientFactory.swift
import Foundation

enum ClientFactory {
    static func makeClient(for config: ServerConfig) -> any AnyFTPClient {
        switch config.protocol_ {
        case .ftp, .ftps: return FTPClient(config: config)
        case .sftp:        return SFTPClient(config: config)
        }
    }
}
