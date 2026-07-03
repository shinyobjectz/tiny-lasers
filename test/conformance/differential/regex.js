var text = "2024-01-15 and 2025-12-31";
print(text.replace(/(\d{4})-(\d{2})-(\d{2})/g, "$3/$2/$1"));
var m = "user@example.com".match(/^([^@]+)@(.+)$/);
print(m[1] + " AT " + m[2]);
print("" + /\d+/.test("abc123") + "," + "a1b2c3".split(/\d/).join("|"));
var re = /(\w)(\w)/g, out = [], mm;
while ((mm = re.exec("abcdef")) !== null) { out.push(mm[1] + mm[2]); }
print(out.join(","));
