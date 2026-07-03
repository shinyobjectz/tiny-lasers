var data = { id: 42, items: [{ n: "x", v: 1 }, { n: "y", v: 2 }], active: true, note: null };
var s = JSON.stringify(data);
print(s);
var back = JSON.parse(s);
print("" + back.id + "," + back.items[1].n + "," + back.active + "," + back.note);
print(JSON.stringify([1, "two", true, null, { k: "v" }]));
print(JSON.stringify({ a: 1 }, null, 2));
