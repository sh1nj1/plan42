import { formatFileSize } from "../attachment_payload"

describe("formatFileSize", () => {
  it("formats byte counts with the largest fitting unit", () => {
    expect(formatFileSize(512)).toBe("512 B")
    expect(formatFileSize("2048")).toBe("2 KB")
    expect(formatFileSize(1536)).toBe("1.5 KB")
    expect(formatFileSize(1024 ** 5)).toBe("1024 TB")
  })

  it("returns an empty string for missing or invalid sizes", () => {
    expect(formatFileSize(null)).toBe("")
    expect(formatFileSize(undefined)).toBe("")
    expect(formatFileSize("abc")).toBe("")
    expect(formatFileSize(0)).toBe("")
  })
})
