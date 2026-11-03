import Foundation

let url = URL(fileURLWithPath: "/tmp/empty-ci-probe")
try Data().write(to: url)
for _ in 0 ..< 3 {
    let data = try Data(contentsOf: url)
    print(data.count)
}
