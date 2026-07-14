#if canImport(XCTest)
import XCTest
@testable import RebesCore

final class SafeCleanerTests: XCTestCase {
    func testWhitelistGuard() {
        let cleaner = SafeCleaner.shared
        
        // Rejects /System and /Applications root
        XCTAssertFalse(cleaner.isAllowed(path: "/System"))
        XCTAssertFalse(cleaner.isAllowed(path: "/Applications"))
        XCTAssertFalse(cleaner.isAllowed(path: "/System/Library"))
        
        // Rejects arbitrary paths outside $HOME
        XCTAssertFalse(cleaner.isAllowed(path: "/usr/local/bin"))
        XCTAssertFalse(cleaner.isAllowed(path: "/tmp/somefile"))
        
        // Rejects $HOME root
        XCTAssertFalse(cleaner.isAllowed(path: cleaner.homeDir))
        
        // Allows inside Applications
        XCTAssertTrue(cleaner.isAllowed(path: "/Applications/SomeApp.app"))
        
        // Allows inside $HOME
        XCTAssertTrue(cleaner.isAllowed(path: "\(cleaner.homeDir)/Library/Caches/SomeCache"))
        XCTAssertTrue(cleaner.isAllowed(path: "\(cleaner.homeDir)/Downloads/LargeFile.zip"))
    }
}
#endif
