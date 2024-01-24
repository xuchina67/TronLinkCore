import UIKit
import CryptoSwift
import secp256k1_swift

enum TronMessageSignV2Type {
    //v2
    case SIGN_MESSAGE_V2_STRING
    case SIGN_MESSAGE_V2_HASHSTRING
    case SIGN_MESSAGE_V2_ARRAY
}

class TronLinkCore: NSObject {

    @objc static let shareManager = TronLinkCore()
    
    let keyStore: KeyStore
    let keysDirectory: URL

    private let datadir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]

    private init(
        keysSubfolder: String = "/keystore",
        userDefaults: UserDefaults = UserDefaults.standard
    ) {
        self.keysDirectory = URL(fileURLWithPath: datadir + keysSubfolder)
        self.keyStore = try! KeyStore(keyDirectory: keysDirectory)
        
    }
    
    var memoryPasswordArray: Array = Array<MemoryAESPasswordModel>()
    
}

class MemoryAESPasswordModel: NSObject {
    var address: String = ""
    var aesPassword: String = ""
}

//MARK: - Create
extension TronLinkCore {
    func createWalletAccount(password: String, completion: @escaping (Result<Account, KeystoreError>) -> Void) {
        do {
            let account = try keyStore.createAccount(password: password, type: .hierarchicalDeterministicWallet)
            completion(.success(account))
        } catch {
            completion(.failure(.failedToCreateWallet))
        }
    }
}

//MARK: - Export
extension TronLinkCore {
    func walletExportPrivateKey(password: String, address: String) -> String {
        for account in self.keyStore.accounts {
            if address == account.address.data.addressString {
                do {
                    var privateKey = try self.keyStore.exportPrivateKey(account: account, password: password)
                    defer {
                        privateKey = Data()
                    }
                    return privateKey.hexString
                } catch _ {}
            }
        }
        return ""
    }
    
    
    func walletExportMnemonic(password: String, address: String) -> String {

        for account in self.keyStore.accounts {
            if address == account.address.data.addressString {
                do {
                    var mnemonic = try self.keyStore.exportMnemonic(account: account, password: password)
                    defer {
                        mnemonic = ""
                    }
                    return mnemonic
                } catch _ {}
            }
        }
        return ""
    }
}

//MARK: - Sign
extension TronLinkCore {
    
    /// sign tron transaction
    /// - Parameters:
    ///   - transaction: Transaction
    ///   - password: wallet password
    ///   - address: wallet address
    ///   - dappChainId: Optional, defalut is mainChain, dappChainId needs to pass in ChianId
    /// - Returns: signed TronTransaction
    func signTranscation(transaction: TronTransaction, password: String, address: String, _ dappChainId: String = "") -> Result<TronTransaction, KeystoreError> {
        
        for account in self.keyStore.accounts {
            if address == account.address.data.addressString {
                if let hash: Data = transaction.rawData.data()?.sha256(), let list = transaction.rawData.contractArray, list.count > 0 {
                    for _ in list {
                        var newHash: Data = hash
                        if !dappChainId.isEmpty {
                            if let mainGateData = Data(hexString: dappChainId) {
                                newHash.append(mainGateData)
                                newHash = newHash.sha256()
                            }
                        }
                        do {
                            var data = try keyStore.signHash(newHash, account: account, password: password)
                            if data[64] >= 27 {
                                data[64] -= 27
                            }
                            transaction.signatureArray.add(data as Any)
                            return .success(transaction)
                        } catch _ {
                            return .failure(KeystoreError.failedToSignTransaction)
                        }
                    }
                } else {
                    return .failure(KeystoreError.failedToParseJSON)
                }
            }
        }
        return .failure(KeystoreError.failedToSignTransaction)
    }
    
    /// sign string
    /// - Parameters:
    ///   - unSignedString: string
    ///   - password: wallet password
    ///   - address: wallet address
    /// - Returns: signed string
    func signString(unSignedString: String, password: String, address: String) -> String {
        let signString = unSignedString.signStringHexEncoded
        let privatekey = walletExportPrivateKey(password: password, address: address)
        let privatekeyData = Data.init(hex: privatekey)
        let persondata = Data.init(hex: signString)

        var apendData = Data()
        let prefix = "\u{19}TRON Signed Message:\n32"
        guard let prefixData = prefix.data(using: .ascii) else { return "" }
        apendData.append(prefixData)
        apendData.append(persondata)

        let sha3 = SHA3(variant: .keccak256)
        let Sh3Data =  Data(sha3.calculate(for: apendData.bytes))
            
        let  serializedSignature = SECP256K1.signForRecovery(hash: Sh3Data, privateKey: privatekeyData).serializedSignature ?? Data()
        
        guard let unmarshalledSignature = SECP256K1.unmarshalSignature(signatureData: serializedSignature) else {
            return ""
        }
        
        return unmarshalledSignature.r.toHexString().add0x + unmarshalledSignature.s.toHexString() + unmarshalledSignature.v.description.hex
    }
    
    /// sign string v2
    /// - Parameters:
    ///   - unSignedString: v2 string
    ///   - password: wallet password
    ///   - address: wallet address
    ///   - messageType: Optional, defalut is SIGN_MESSAGE_V2_STRING
    /// - Returns: signed string
    func signStringV2(unSignedString: String, password: String, address: String, _ messageType:TronMessageSignV2Type = .SIGN_MESSAGE_V2_STRING) -> String {
        let privatekey = walletExportPrivateKey(password: password, address: address)
        let privatekeyData = Data.init(hex: privatekey)

        var persondata = Data.init(hex: unSignedString)
        if case .SIGN_MESSAGE_V2_ARRAY = messageType { //bytes
            let list = unSignedString.split(separator: ",")
            var byteList:[UInt8] = [UInt8]()
            list.forEach { item in
                if let value = (UInt8)(String(item)) {
                    byteList.append(value)
                }
            }
            persondata = Data.init(byteList)
        }else if case .SIGN_MESSAGE_V2_STRING = messageType { //String
            persondata = unSignedString.data(using: .utf8) ?? Data()
        }else if case .SIGN_MESSAGE_V2_HASHSTRING = messageType { //HexStringType
            persondata = Data.init(hex: unSignedString)
        }

        let prefix = "\u{19}TRON Signed Message:\n\(persondata.count)"
        guard let prefixData = prefix.data(using: .ascii) else { return "" }

        var apendData = Data()
        apendData.append(prefixData)
        apendData.append(persondata)

        let sha3 = SHA3(variant: .keccak256)
        let Sh3Data =  Data(sha3.calculate(for: apendData.bytes))
        
        let  serializedSignature = SECP256K1.signForRecovery(hash: Sh3Data, privateKey: privatekeyData).serializedSignature ?? Data()
        
        guard let unmarshalledSignature = SECP256K1.unmarshalSignature(signatureData: serializedSignature) else {
            return ""
        }
        
        return unmarshalledSignature.r.toHexString().add0x + unmarshalledSignature.s.toHexString() + unmarshalledSignature.v.description.hex
    }
}

//MARK: - Address
extension TronLinkCore {
    
    func isTRXAddress() -> Bool {
//        if self.isEmpty {
//            return false
//        }
//        
//        let data = self.base58CheckData
//        if data == nil {
//            return false
//        }
//        
//        var string = data?.toHexString()
//        
//        if string?.hasPrefix("0x") ?? false {
//            string = string?.substring(from: 2)
//        }
//        
//        if (string?.hasPrefix("41") ?? false) && (string?.count ?? 0) == 42 {
//            return true
//        }
        return false
    }
}

