import Foundation

final class SingleInstanceGuard {
    private let lockFilePath: String
    private var lockFileDescriptor: Int32 = -1

    init(lockName: String) {
        let sanitizedName = lockName.replacingOccurrences(of: "/", with: "_")
        lockFilePath = "/tmp/\(sanitizedName).lock"
    }

    deinit {
        releaseLock()
    }

    func acquireLock() -> Bool {
        let fd = open(lockFilePath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return false
        }

        let result = flock(fd, LOCK_EX | LOCK_NB)
        guard result == 0 else {
            close(fd)
            return false
        }

        lockFileDescriptor = fd
        return true
    }

    private func releaseLock() {
        guard lockFileDescriptor >= 0 else {
            return
        }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }
}
