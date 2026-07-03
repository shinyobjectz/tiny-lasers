var s = "The Quick Brown Fox";
print(s.toUpperCase());
print(s.toLowerCase());
print(s.split(" ").reverse().join("-"));
print(s.replace(/o/g, "0"));
print(s.slice(4, 9) + "|" + s.substring(4, 9) + "|" + s.substr(4, 5));
print("" + s.indexOf("Brown") + "," + s.includes("Fox") + "," + s.startsWith("The") + "," + s.endsWith("Fox"));
print("pad".padStart(6, "*") + "|" + "pad".padEnd(6, "*"));
print("  trim me  ".trim() + "|" + "aaa".repeat(3));
