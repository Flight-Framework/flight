import Crypto
import Foundation
import SwiftASN1
import X509

/// A throwaway certificate authority and server certificate, generated fresh
/// for each test run.
///
/// Generated rather than committed: a checked-in key is a key, however loudly
/// a comment says otherwise — secret scanners flag it, and a reviewer has to
/// verify the claim. Generated material also cannot expire out from under the
/// suite the way a fixture eventually does.
enum TLSFixture {

    struct Material {
        let caCertificatePEM: String
        let serverCertificatePEM: String
        let serverKeyPEM: String
        let clientCertificatePEM: String
        let clientKeyPEM: String
    }

    /// Writes the material to `directory` and hands back the paths, in the
    /// shape `FlightTransportConfiguration.TLS` expects.
    static func write(to directory: URL) throws -> (
        material: Material,
        serverChain: String, serverKey: String,
        caRoots: String, clientChain: String, clientKey: String
    ) {
        let material = try generate()
        func put(_ contents: String, _ name: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        return (
            material,
            try put(material.serverCertificatePEM, "server.crt"),
            try put(material.serverKeyPEM, "server.key"),
            try put(material.caCertificatePEM, "ca.crt"),
            try put(material.clientCertificatePEM, "client.crt"),
            try put(material.clientKeyPEM, "client.key")
        )
    }

    static func generate() throws -> Material {
        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)
        let notAfter = now.addingTimeInterval(3600 * 24)

        // Root CA.
        let caKey = P256.Signing.PrivateKey()
        let caName = try DistinguishedName { CommonName("Flight Test CA") }
        let ca = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(caKey.publicKey),
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: caName,
            subject: caName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 1))
                Critical(KeyUsage(keyCertSign: true))
            },
            issuerPrivateKey: Certificate.PrivateKey(caKey))

        func leaf(
            commonName: String,
            subjectAlternativeNames: [GeneralName],
            usage: ExtendedKeyUsage.Usage
        ) throws -> (certificate: Certificate, key: P256.Signing.PrivateKey) {
            let key = P256.Signing.PrivateKey()
            let certificate = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: Certificate.PublicKey(key.publicKey),
                notValidBefore: notBefore,
                notValidAfter: notAfter,
                issuer: caName,
                subject: try DistinguishedName { CommonName(commonName) },
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                    try ExtendedKeyUsage([usage])
                    SubjectAlternativeNames(subjectAlternativeNames)
                },
                issuerPrivateKey: Certificate.PrivateKey(caKey))
            return (certificate, key)
        }

        let server = try leaf(
            commonName: "localhost",
            subjectAlternativeNames: [
                .dnsName("localhost"),
                .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
            ],
            usage: .serverAuth)
        let client = try leaf(
            commonName: "Flight Test Client",
            subjectAlternativeNames: [.dnsName("client.test")],
            usage: .clientAuth)

        return Material(
            caCertificatePEM: try ca.serializeAsPEM().pemString,
            serverCertificatePEM: try server.certificate.serializeAsPEM().pemString,
            serverKeyPEM: try Certificate.PrivateKey(server.key).serializeAsPEM().pemString,
            clientCertificatePEM: try client.certificate.serializeAsPEM().pemString,
            clientKeyPEM: try Certificate.PrivateKey(client.key).serializeAsPEM().pemString)
    }
}
