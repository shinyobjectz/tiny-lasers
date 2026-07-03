var a = [5, 3, 8, 1, 9, 2, 7];
print(a.map(function(x){ return x * 2; }).join(","));
print(a.filter(function(x){ return x % 2 === 1; }).join(","));
print("" + a.reduce(function(s, x){ return s + x; }, 0));
print(a.slice().sort(function(x, y){ return x - y; }).join(","));
print("" + a.find(function(x){ return x > 6; }) + "," + a.some(function(x){ return x > 8; }) + "," + a.every(function(x){ return x > 0; }));
print([[1, 2], [3, 4], [5]].flat().join(","));
print(a.concat([10, 11]).slice(-3).join(","));
print("" + a.indexOf(8) + "," + a.lastIndexOf(2) + "," + a.includes(9));
