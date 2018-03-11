import NIO
import CNIOLinux
import Glibc

private func isBlacklistedErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT:
        fallthrough
    case EBADF:
        return true
    default:
        return false
    }
}

private func toEpollEvents(interested: IOEvent) -> UInt32 {
    // Also merge EPOLLRDHUP in so we can easily detect connection-reset
    switch interested {
    case .read:
        return Epoll.EPOLLIN.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
    case .write:
        return Epoll.EPOLLOUT.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
    case .all:
        return Epoll.EPOLLIN.rawValue | Epoll.EPOLLOUT.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
    case .none:
        return Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue
    }
}

@inline(__always)
internal func wrapSyscall<T: FixedWidthInteger>(where function: StaticString = #function, _ body: () throws -> T) throws -> T {
    while true {
        let res = try body()
        if res == -1 {
            let err = errno
            if err == EINTR {
                continue
            }
            assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
            throw IOError(errnoCode: err, function: function)
        }
        return res
    }
}

internal enum TimerFd {
    public static let TFD_CLOEXEC = CNIOLinux.TFD_CLOEXEC
    public static let TFD_NONBLOCK = CNIOLinux.TFD_NONBLOCK
    
    @inline(never)
    public static func timerfd_settime(fd: Int32, flags: Int32, newValue: UnsafePointer<itimerspec>, oldValue: UnsafeMutablePointer<itimerspec>?) throws  {
        _ = try wrapSyscall {
            CNIOLinux.timerfd_settime(fd, flags, newValue, oldValue)
        }
    }
    
    @inline(never)
    public static func timerfd_create(clockId: Int32, flags: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.timerfd_create(clockId, flags)
        }
    }
}

internal enum EventFd {
    public static let EFD_CLOEXEC = CNIOLinux.EFD_CLOEXEC
    public static let EFD_NONBLOCK = CNIOLinux.EFD_NONBLOCK
    public typealias eventfd_t = CNIOLinux.eventfd_t
    
    @inline(never)
    public static func eventfd_write(fd: Int32, value: UInt64) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.eventfd_write(fd, value)
        }
    }
    
    @inline(never)
    public static func eventfd_read(fd: Int32, value: UnsafeMutablePointer<UInt64>) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.eventfd_read(fd, value)
        }
    }
    
    @inline(never)
    public static func eventfd(initval: Int32, flags: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.eventfd(0, Int32(EFD_CLOEXEC | EFD_NONBLOCK))
        }
    }
}

internal enum Epoll {
    public typealias epoll_event = CNIOLinux.epoll_event
    public static let EPOLL_CTL_ADD = CNIOLinux.EPOLL_CTL_ADD
    public static let EPOLL_CTL_MOD = CNIOLinux.EPOLL_CTL_MOD
    public static let EPOLL_CTL_DEL = CNIOLinux.EPOLL_CTL_DEL
    public static let EPOLLIN = CNIOLinux.EPOLLIN
    public static let EPOLLOUT = CNIOLinux.EPOLLOUT
    public static let EPOLLERR = CNIOLinux.EPOLLERR
    public static let EPOLLRDHUP = CNIOLinux.EPOLLRDHUP
    public static let EPOLLET = CNIOLinux.EPOLLET
    
    @inline(never)
    public static func epoll_create(size: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.epoll_create(size)
        }
    }
    
    @inline(never)
    public static func epoll_ctl(epfd: Int32, op: Int32, fd: Int32, event: UnsafeMutablePointer<epoll_event>) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.epoll_ctl(epfd, op, fd, event)
        }
    }
    
    @inline(never)
    public static func epoll_wait(epfd: Int32, events: UnsafeMutablePointer<epoll_event>, maxevents: Int32, timeout: Int32) throws -> Int32 {
        return try wrapSyscall {
            CNIOLinux.epoll_wait(epfd, events, maxevents, timeout)
        }
    }
}

let fd = try Epoll.epoll_create(size: 128)
let eventfd = try EventFd.eventfd(initval: 0, flags: Int32(EventFd.EFD_CLOEXEC | EventFd.EFD_NONBLOCK))
let timerfd = try TimerFd.timerfd_create(clockId: CLOCK_MONOTONIC, flags: Int32(TimerFd.TFD_CLOEXEC | TimerFd.TFD_NONBLOCK))

var ev = Epoll.epoll_event()
ev.events = toEpollEvents(interested: .read)
ev.data.fd = eventfd

_ = try Epoll.epoll_ctl(epfd: fd, op: Epoll.EPOLL_CTL_ADD, fd: eventfd, event: &ev)

var timerev = Epoll.epoll_event()
timerev.events = Epoll.EPOLLIN.rawValue | Epoll.EPOLLERR.rawValue | Epoll.EPOLLRDHUP.rawValue | Epoll.EPOLLET.rawValue
timerev.data.fd = timerfd
_ = try Epoll.epoll_ctl(epfd: fd, op: Epoll.EPOLL_CTL_ADD, fd: timerfd, event: &timerev)
