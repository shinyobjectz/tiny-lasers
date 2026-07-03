class Shape { constructor(name){ this.name = name; } describe(){ return "a " + this.name; } }
class Circle extends Shape {
  constructor(r){ super("circle"); this.r = r; }
  area(){ return Math.round(3.14159 * this.r * this.r * 100) / 100; }
  describe(){ return super.describe() + " with r=" + this.r; }
}
var c = new Circle(5);
print(c.describe());
print("" + c.area());
print("" + (c instanceof Circle) + "," + (c instanceof Shape));
