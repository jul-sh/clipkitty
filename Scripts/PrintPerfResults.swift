import Foundation

let logPath = "xcodebuild.log"
guard let content = try? String(contentsOfFile: logPath) else {
    print("Could not read xcodebuild.log. Make sure to run xcodebuild and pipe output to this file.")
    exit(0)
}

let lines = content.components(separatedBy: .newlines)
var found = false

print("\n🚀 UI Performance Test Results:")
print("================================")

let testCasePattern = "Test Case '-\\[(.*?)\\]'"
let averagePattern = "average: ([0-9.]+), "
let metricPattern = "measured \\\\[(.*?)\\\]"
let rsdPattern = "relative standard deviation: ([0-9.]+%?), "

func match(pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let nsString = text as NSString
    let results = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsString.length))
    if let result = results, result.numberOfRanges > 1 {
        return nsString.substring(with: result.range(at: 1))
    }
    return nil
}

var lastTestCase: String? = nil

for line in lines {
    if line.contains("measured") {
        found = true
        
        let testCase = match(pattern: testCasePattern, in: line) ?? "Unknown Test"
        let averageStr = match(pattern: averagePattern, in: line) ?? "0"
        let metric = match(pattern: metricPattern, in: line) ?? "Metric"
        let rsd = match(pattern: rsdPattern, in: line) ?? "N/A"
        
        let testName = testCase.components(separatedBy: " ").last?.replacingOccurrences(of: "]", with: "") ?? testCase
        
        if lastTestCase != testName {
            print("\n📊 \(testName)")
            lastTestCase = testName
        }
        
        var formattedAverage = averageStr
        if metric.lowercased().contains("seconds") {
            if let val = Double(averageStr) {
                if val < 1.0 {
                    formattedAverage = String(format: "%.2f ms", val * 1000)
                } else {
                    formattedAverage = String(format: "%.3f s", val)
                }
            }
        }
        
        print("   • \(metric):")
        print("     Average: \(formattedAverage)")
        print("     RSD:     \(rsd)")
    }
}

if !found {
    print("\nNo performance metrics found in logs.")
}
print("\n================================\n")
