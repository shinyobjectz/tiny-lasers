function quicksort(arr){
  if (arr.length <= 1) return arr;
  var pivot = arr[0], less = [], more = [];
  for (var i = 1; i < arr.length; i++){ (arr[i] < pivot ? less : more).push(arr[i]); }
  return quicksort(less).concat([pivot], quicksort(more));
}
print(quicksort([9, 3, 7, 1, 8, 2, 6, 5, 4]).join(","));
function parseCSV(s){
  return s.split("\n").map(function(line){ return line.split(","); });
}
var rows = parseCSV("a,b,c\n1,2,3\n4,5,6");
print(rows.map(function(r){ return r.join("|"); }).join(" ; "));
function tmpl(str, ctx){ return str.replace(/\{(\w+)\}/g, function(_, k){ return ctx[k]; }); }
print(tmpl("Hello {name}, you have {n} messages", { name: "Sam", n: 7 }));
