/// A Point is an X, Y coordinate pair. The axes increase right and down.
pub const Point = struct {
    x: i32,
    y: i32,

    pub fn In(self: Point, r: Rectangle) bool {
        return self.x >= r.min.x and self.x < r.max.x and self.y >= r.min.y and self.y < r.max.y;
    }
};

/// A Rectangle contains the points with Min.X <= X < Max.X, Min.Y <= Y < Max.Y.
/// It is well-formed if Min.X <= Max.X and likewise for Y. Points are always
/// well-formed. A rectangle's methods always return well-formed outputs for
/// well-formed inputs.
pub const Rectangle = struct {
    min: Point,
    max: Point,

    pub fn init(x0: i32, y0: i32, x1: i32, y1: i32) Rectangle {
        const x_min = if (x0 > x1) x1 else x0;
        const x_max = if (x0 > x1) x0 else x1;
        const y_min = if (y0 > y1) y1 else y0;
        const y_max = if (y0 > y1) y0 else y1;

        return Rectangle{
            .min = .{ .x = x_min, .y = y_min },
            .max = .{ .x = x_max, .y = y_max },
        };
    }

    pub fn dX(self: Rectangle) i32 {
        return self.max.x - self.min.x;
    }
    pub fn dY(self: Rectangle) i32 {
        return self.max.y - self.min.y;
    }
    pub fn size(self: Rectangle) Point {
        return Point{
            .x = self.max.x - self.min.x,
            .y = self.max.y - self.min.y,
        };
    }
    // Intersect returns the largest rectangle contained by both self and other. If the
    // two rectangles do not overlap then null will be returned.
    pub fn Intersect(self: Rectangle, other: Rectangle) ?Rectangle {
        const x0 = if (self.min.x > other.min.x) self.min.x else other.min.x;
        const y0 = if (self.min.y > other.min.y) self.min.y else other.min.y;
        const x1 = if (self.max.x < other.max.x) self.max.x else other.max.x;
        const y1 = if (self.max.y < other.max.y) self.max.y else other.max.y;

        if (x0 >= x1 or y0 >= y1) return null;

        return Rectangle.init(x0, y0, x1, y1);
    }
};
