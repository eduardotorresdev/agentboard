//! A diagram an agent shows as decision evidence, checked the way `SVGDiagram.swift` checks it.
//! The boards draw it (CoreGraphics, Mac and phone alike); the core only decides whether it can
//! be drawn, so this is that file's parser and rules without the drawing. Both refuse the same
//! diagrams for the same reasons: `core/fixtures/diagrams/cases.json` holds the cases each side
//! is tested against.

use std::collections::{HashMap, HashSet};

use quick_xml::events::Event;
use quick_xml::Reader;

pub const MAX_BYTES: usize = 262_144;
pub const MAX_ELEMENTS: usize = 2_000;
/// How deep `g`, `use` and `marker` may nest, counting what a `use` brings in.
pub const MAX_DEPTH: usize = 16;

const MALFORMED: &str = "The diagram isn't well-formed XML.";

type Refusal = String;

/// Nothing when `text` can be drawn, else why not, in the words the Swift renderer uses.
pub fn check(text: &str) -> Result<(), Refusal> {
    if text.len() > MAX_BYTES {
        return Err(format!("The diagram is {} bytes; the limit is {MAX_BYTES}. Draw less, or split it into cards.", text.len()));
    }
    // No DTD at all: entities are the classic way to blow a small file up.
    let lowered = text.to_ascii_lowercase();
    if lowered.contains("<!doctype") || lowered.contains("<!entity") {
        return Err("A diagram takes no DOCTYPE or entities.".into());
    }
    let root = parse(text)?;
    if root.name != "svg" {
        return Err(format!("A diagram is one `<svg>` element; this starts with `<{}>`.", root.name));
    }
    let (width, height) = if let Some(text) = root.attribute("viewBox") {
        let values = list(text, "viewBox")?;
        if values.len() != 4 {
            return Err("`viewBox` takes four numbers: x y width height.".into());
        }
        if !(values[2] > 0.0 && values[3] > 0.0) {
            return Err("Give the diagram a `viewBox` with a width and height above 0.".into());
        }
        (values[2], values[3])
    } else {
        (length(root.attribute("width").unwrap_or("0"), "width")?, length(root.attribute("height").unwrap_or("0"), "height")?)
    };
    if !(width > 0.0 && height > 0.0) {
        return Err("Give the diagram a `viewBox` (or `width` and `height`) with a width and height above 0.".into());
    }
    Builder::new(&root).build()
}

struct Node {
    name: String,
    attributes: Vec<(String, String)>,
    children: Vec<Node>,
    text: String,
}

impl Node {
    fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str())
    }
}

/// The element tree. quick-xml reads no DTD and expands no entity beyond XML's five and
/// character references: anything else is a malformed diagram.
fn parse(text: &str) -> Result<Node, Refusal> {
    let mut reader = Reader::from_str(text);
    reader.config_mut().trim_text(false);
    reader.config_mut().check_end_names = true;
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;
    let mut count = 0;
    let malformed = |_| MALFORMED.to_string();
    loop {
        let event = reader.read_event().map_err(|_| MALFORMED.to_string())?;
        let (start, empty) = match &event {
            Event::Start(start) => (Some(start.clone()), false),
            Event::Empty(start) => (Some(start.clone()), true),
            _ => (None, false),
        };
        if let Some(start) = start {
            if root.is_some() {
                return Err(MALFORMED.into());
            }
            count += 1;
            if count > MAX_ELEMENTS {
                return Err(format!("The diagram has more than {MAX_ELEMENTS} elements. Draw less, or split it into cards."));
            }
            if stack.len() > MAX_DEPTH {
                return Err(format!("The diagram nests deeper than {MAX_DEPTH} levels. Flatten its groups."));
            }
            let name = String::from_utf8(start.name().as_ref().to_vec()).map_err(|_| MALFORMED.to_string())?;
            let mut attributes = Vec::new();
            for attribute in start.attributes() {
                let attribute = attribute.map_err(|_| MALFORMED.to_string())?;
                let key = String::from_utf8(attribute.key.as_ref().to_vec()).map_err(|_| MALFORMED.to_string())?;
                let value = attribute.unescape_value().map_err(malformed)?.into_owned();
                attributes.push((key, value));
            }
            stack.push(Node { name, attributes, children: Vec::new(), text: String::new() });
            if !empty {
                continue;
            }
        }
        match event {
            Event::Start(_) => {}
            Event::Empty(_) | Event::End(_) => {
                let Some(node) = stack.pop() else { return Err(MALFORMED.into()) };
                match stack.last_mut() {
                    Some(parent) => parent.children.push(node),
                    None => root = Some(node),
                }
            }
            Event::Text(text) => {
                let text = text.unescape().map_err(malformed)?;
                match stack.last_mut() {
                    Some(node) => node.text.push_str(&text),
                    None if text.trim().is_empty() => {}
                    None => return Err(MALFORMED.into()),
                }
            }
            Event::CData(data) => match stack.last_mut() {
                Some(node) => node.text.push_str(&String::from_utf8_lossy(&data)),
                None => return Err(MALFORMED.into()),
            },
            Event::DocType(_) => return Err("A diagram takes no DOCTYPE or entities.".into()),
            Event::PI(pi) => {
                if pi.target() != b"xml" {
                    return Err("A diagram takes no processing instructions.".into());
                }
            }
            Event::Decl(_) | Event::Comment(_) => {}
            Event::Eof => break,
        }
    }
    match root {
        Some(root) if stack.is_empty() => Ok(root),
        _ => Err(MALFORMED.into()),
    }
}

fn trimmed(text: &str) -> &str {
    text.trim_matches(|c: char| c == ' ' || c == '\t')
}

fn number(text: &str, name: &str) -> Result<f64, Refusal> {
    match trimmed(text).parse::<f64>() {
        Ok(value) if value.is_finite() => Ok(value),
        _ => Err(format!("`{name}` must be a finite number; it is “{text}”.")),
    }
}

/// A length: a number, `px` allowed; other units and percentages are refused.
fn length(text: &str, name: &str) -> Result<f64, Refusal> {
    let mut value = trimmed(text);
    if let Some(rest) = value.strip_suffix("px") {
        value = rest;
    }
    if value.ends_with('%') {
        return Err(format!("`{name}` is a percentage; give it in the viewBox's units."));
    }
    number(value, name)
}

fn list(text: &str, name: &str) -> Result<Vec<f64>, Refusal> {
    text.split(|c: char| c == ',' || c.is_whitespace()).filter(|part| !part.is_empty()).map(|part| number(part, name)).collect()
}

/// Elements that draw or hold others; `title`, `desc` and `metadata` are read and skipped.
const DRAWN: [&str; 11] = ["g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "use", "defs"];
const SKIPPED: [&str; 3] = ["title", "desc", "metadata"];

/// Attributes that would change the drawing in ways the renderer doesn't draw.
fn refused_attribute(name: &str) -> Option<&'static str> {
    Some(match name {
        "style" => "CSS isn't drawn: give `fill`, `stroke` and the rest as attributes.",
        "clip-path" => "Clipping isn't drawn.",
        "mask" => "Masks aren't drawn.",
        "filter" => "Filters (blur, shadow) aren't drawn.",
        "marker-start" | "marker-mid" | "marker" => "Only `marker-end` is drawn.",
        "visibility" => "`visibility` isn't drawn: leave the element out.",
        "display" => "`display` isn't drawn: leave the element out.",
        "font-style" => "Text is drawn in the system font, upright.",
        "writing-mode" => "Text is drawn left to right.",
        "lengthAdjust" | "textLength" => "Text keeps its own width.",
        "paint-order" => "Fill is drawn before stroke.",
        "vector-effect" => "`vector-effect` isn't drawn.",
        _ => return None,
    })
}

struct Builder<'a> {
    root: &'a Node,
    ids: HashMap<&'a str, &'a Node>,
    markers: HashSet<String>,
    /// The `use` targets being expanded, to refuse one that brings itself in.
    expanding: HashSet<String>,
    /// Elements drawn so far, `use` copies included, so reuse can't multiply past the cap.
    drawn: usize,
}

impl<'a> Builder<'a> {
    fn new(root: &'a Node) -> Self {
        fn collect<'a>(node: &'a Node, ids: &mut HashMap<&'a str, &'a Node>) {
            if let Some(id) = node.attribute("id") {
                ids.insert(id, node);
            }
            node.children.iter().for_each(|child| collect(child, ids));
        }
        let mut ids = HashMap::new();
        collect(root, &mut ids);
        Builder { root, ids, markers: HashSet::new(), expanding: HashSet::new(), drawn: 0 }
    }

    fn build(mut self) -> Result<(), Refusal> {
        self.children(self.root, 0)
    }

    fn children(&mut self, node: &'a Node, depth: usize) -> Result<(), Refusal> {
        node.children.iter().try_for_each(|child| self.element(child, depth + 1))
    }

    fn element(&mut self, node: &'a Node, depth: usize) -> Result<(), Refusal> {
        let name = node.name.as_str();
        if SKIPPED.contains(&name) {
            return Ok(());
        }
        if name == "marker" {
            return match node.attribute("id") {
                Some(_) => Ok(()),
                None => Err("A `<marker>` needs an `id` for `marker-end` to name it.".into()),
            };
        }
        if !DRAWN.contains(&name) {
            let hint = match name {
                "linearGradient" | "radialGradient" | "pattern" => " Fills are solid colors.",
                "image" | "foreignObject" => " A diagram draws shapes and text only.",
                "tspan" | "textPath" => " Text is one `<text>` per line.",
                "style" => " CSS isn't drawn: give colors as attributes.",
                "svg" => " Nest groups (`<g>`), not another `<svg>`.",
                _ => "",
            };
            return Err(format!("`<{name}>` isn't drawn.{hint}"));
        }
        if depth > MAX_DEPTH {
            return Err(format!("The diagram nests deeper than {MAX_DEPTH} levels. Flatten its groups."));
        }
        if name == "defs" {
            return Ok(());
        }
        self.drawn += 1;
        if self.drawn > MAX_ELEMENTS {
            return Err(format!("The diagram draws more than {MAX_ELEMENTS} elements, `use` copies included. Draw less."));
        }
        for (key, _) in &node.attributes {
            if let Some(reason) = refused_attribute(key) {
                return Err(format!("`{key}` on `<{name}>`: {reason}"));
            }
        }
        transform(node.attribute("transform"))?;
        if let Some(marker) = style(node)? {
            self.marker(&marker)?;
        }
        let number = |key: &str| node.attribute(key).map_or(Ok(0.0), |value| length(value, key));
        match name {
            "g" => self.children(node, depth),
            "use" => {
                let reference = node.attribute("href").or_else(|| node.attribute("xlink:href"));
                let Some(id) = reference.and_then(|reference| reference.strip_prefix('#')) else {
                    return Err("`<use>` takes an `href` to an element of the diagram (`#id`).".into());
                };
                let Some(target) = self.ids.get(id).copied() else {
                    return Err(format!("`<use>` names `#{id}`, which the diagram doesn't have."));
                };
                if self.expanding.contains(id) {
                    return Err(format!("`<use>` brings in `#{id}` inside itself."));
                }
                number("x")?;
                number("y")?;
                self.expanding.insert(id.to_string());
                let result = self.element(target, depth + 1);
                self.expanding.remove(id);
                result
            }
            "rect" => {
                number("x")?;
                number("y")?;
                let (width, height) = (number("width")?, number("height")?);
                if width < 0.0 || height < 0.0 {
                    return Err("A `<rect>` has a negative size.".into());
                }
                for key in ["rx", "ry"] {
                    if let Some(value) = node.attribute(key) {
                        length(value, key)?;
                    }
                }
                Ok(())
            }
            "circle" => ["r", "cx", "cy"].iter().try_for_each(|key| number(key).map(drop)),
            "ellipse" => ["rx", "ry", "cx", "cy"].iter().try_for_each(|key| number(key).map(drop)),
            "line" => ["x1", "y1", "x2", "y2"].iter().try_for_each(|key| number(key).map(drop)),
            "polyline" | "polygon" => {
                let values = list(node.attribute("points").unwrap_or(""), "points")?;
                if values.len() < 4 || values.len() % 2 != 0 {
                    return Err(format!("`points` on `<{name}>` takes pairs of numbers, at least two points."));
                }
                Ok(())
            }
            "path" => path(node.attribute("d").unwrap_or("")),
            "text" => {
                if !node.children.is_empty() {
                    return Err("`<text>` holds plain text only; one `<text>` per line.".into());
                }
                for key in ["x", "y"] {
                    if node.attribute(key).unwrap_or("").contains([' ', ',']) {
                        return Err(format!("`{key}` on `<text>` takes one number."));
                    }
                }
                if node.text.split_whitespace().next().is_some() {
                    number("x")?;
                    number("y")?;
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }

    fn marker(&mut self, reference: &str) -> Result<(), Refusal> {
        let id = url(reference, "marker-end")?;
        if self.markers.contains(&id) {
            return Ok(());
        }
        let node = match self.ids.get(id.as_str()).copied() {
            Some(node) if node.name == "marker" => node,
            _ => return Err(format!("`marker-end` names `#{id}`, which isn't a `<marker>` of the diagram.")),
        };
        if self.expanding.contains(&id) {
            return Err(format!("The marker `#{id}` uses itself."));
        }
        let number = |key: &str, fallback: f64| node.attribute(key).map_or(Ok(fallback), |value| length(value, key));
        let (width, height) = (number("markerWidth", 3.0)?, number("markerHeight", 3.0)?);
        if let Some(text) = node.attribute("viewBox") {
            let values = list(text, "viewBox")?;
            if values.len() != 4 || !(values[2] > 0.0) || !(values[3] > 0.0) {
                return Err("A marker's `viewBox` takes four numbers with a width and height above 0.".into());
            }
        }
        if !(width > 0.0 && height > 0.0) {
            return Err("A marker needs a `markerWidth` and `markerHeight` above 0.".into());
        }
        let orient = node.attribute("orient").unwrap_or("0");
        if orient != "auto" {
            crate::svg_diagram::number(&orient.replace("deg", ""), "orient")?;
        }
        if !["strokeWidth", "userSpaceOnUse"].contains(&node.attribute("markerUnits").unwrap_or("strokeWidth")) {
            return Err("`markerUnits` is strokeWidth or userSpaceOnUse.".into());
        }
        self.expanding.insert(id.clone());
        let result = style(node).and_then(|_| self.children(node, 1));
        self.expanding.remove(&id);
        result?;
        number("refX", 0.0)?;
        number("refY", 0.0)?;
        self.markers.insert(id);
        Ok(())
    }
}

/// Checks an element's presentation attributes; its `marker-end`, if it names one.
fn style(node: &Node) -> Result<Option<String>, Refusal> {
    let get = |key: &str| node.attribute(key);
    if let Some(value) = get("fill") {
        paint(value, "fill")?;
    }
    if let Some(value) = get("stroke") {
        paint(value, "stroke")?;
    }
    if let Some(value) = get("stroke-width") {
        length(value, "stroke-width")?;
    }
    if let Some(value) = get("stroke-dasharray") {
        if value != "none" && list(value, "stroke-dasharray")?.iter().any(|length| *length < 0.0) {
            return Err("`stroke-dasharray` takes lengths of 0 or more.".into());
        }
    }
    let one_of = |key: &str, allowed: &[&str], reason: &str| match get(key) {
        Some(value) if !allowed.contains(&value) => Err(reason.to_string()),
        _ => Ok(()),
    };
    one_of("stroke-linecap", &["butt", "round", "square"], "`stroke-linecap` is butt, round or square.")?;
    one_of("stroke-linejoin", &["miter", "round", "bevel"], "`stroke-linejoin` is miter, round or bevel.")?;
    one_of("fill-rule", &["nonzero", "evenodd"], "`fill-rule` is nonzero or evenodd.")?;
    for key in ["opacity", "fill-opacity", "stroke-opacity"] {
        if let Some(value) = get(key) {
            number(value, key)?;
        }
    }
    if let Some(value) = get("font-size") {
        if length(value, "font-size")? <= 0.0 {
            return Err("`font-size` must be above 0.".into());
        }
    }
    if let Some(value) = get("font-weight") {
        if value.parse::<f64>().is_err() && !["normal", "bold", "bolder", "lighter"].contains(&value) {
            return Err("`font-weight` is normal, bold or a number.".into());
        }
    }
    one_of("text-anchor", &["start", "middle", "end"], "`text-anchor` is start, middle or end.")?;
    Ok(get("marker-end").filter(|value| *value != "none").map(str::to_string))
}

fn url(value: &str, name: &str) -> Result<String, Refusal> {
    match trimmed(value).strip_prefix("url(#").and_then(|rest| rest.strip_suffix(')')) {
        Some(id) => Ok(id.to_string()),
        None => Err(format!("`{name}` takes `url(#id)` naming a `<marker>` of the diagram.")),
    }
}

fn paint(value: &str, name: &str) -> Result<(), Refusal> {
    let value = trimmed(value).to_lowercase();
    if ["none", "black", "white", "transparent"].contains(&value.as_str()) {
        return Ok(());
    }
    if value.starts_with("url(") {
        return Err(format!("`{name}` is a gradient or pattern; fills are solid colors (`#rrggbb`)."));
    }
    let Some(hex) = value.strip_prefix('#').filter(|hex| u32::from_str_radix(hex, 16).is_ok()) else {
        return Err(format!("`{name}` is “{value}”: give a color as `#rrggbb`, `#rgb`, black, white or none."));
    };
    match hex.chars().count() + 1 {
        7 | 4 => Ok(()),
        _ => Err(format!("`{name}` is “{value}”: give a color as `#rrggbb` or `#rgb`.")),
    }
}

fn transform(value: Option<&str>) -> Result<(), Refusal> {
    let Some(mut rest) = value else { return Ok(()) };
    let separators = |c: char| c == ' ' || c == ',' || c == '\t' || c == '\n';
    while let Some(open) = rest.find('(') {
        let name = rest[..open].trim_matches(separators);
        let Some(close) = rest[open..].find(')').map(|at| at + open) else {
            return Err("`transform` is missing a “)”.".into());
        };
        let count = list(&rest[open + 1..close], "transform")?.len();
        let known = matches!((name, count), ("translate" | "scale", 1 | 2) | ("rotate", 1 | 3) | ("skewX" | "skewY", 1) | ("matrix", 6));
        if !known {
            return Err(format!(
                "`transform` has “{name}” with {count} numbers; it takes translate, scale, rotate, skewX, skewY or matrix."
            ));
        }
        rest = &rest[close + 1..];
    }
    if !rest.trim_matches(separators).is_empty() {
        return Err("`transform` has something after its last “)”.".into());
    }
    Ok(())
}

/// A path's `d`, every command, arcs included.
fn path(d: &str) -> Result<(), Refusal> {
    let fail = |reason: &str| format!("`d` on `<path>`: {reason}");
    let mut lexer = Lexer { bytes: d.as_bytes(), index: 0 };
    let mut command: Option<u8> = None;
    let mut any = false;
    loop {
        lexer.skip_separators();
        if lexer.index >= lexer.bytes.len() {
            break;
        }
        if let Some(letter) = lexer.letter() {
            if !b"MmLlHhVvCcSsQqTtAaZz".contains(&letter) {
                return Err(fail(&format!("“{}” isn't a path command.", letter as char)));
            }
            command = Some(letter);
        } else if command.is_none() {
            return Err(fail("it must start with a command (M)."));
        }
        let Some(letter) = command else { break };
        if !any && letter != b'M' && letter != b'm' {
            return Err(fail("it must start with a command (M)."));
        }
        any = true;
        let numbers = |count: usize, lexer: &mut Lexer| -> Result<(), Refusal> {
            for _ in 0..count {
                match lexer.number() {
                    None => return Err(fail("a command is missing its numbers.")),
                    Some(value) if !value.is_finite() => return Err(fail("numbers must be finite.")),
                    Some(_) => {}
                }
            }
            Ok(())
        };
        match letter.to_ascii_uppercase() {
            b'M' => {
                numbers(2, &mut lexer)?;
                // Further pairs are lines.
                command = Some(if letter == b'm' { b'l' } else { b'L' });
            }
            b'L' | b'T' => numbers(2, &mut lexer)?,
            b'H' | b'V' => numbers(1, &mut lexer)?,
            b'C' => numbers(6, &mut lexer)?,
            b'S' | b'Q' => numbers(4, &mut lexer)?,
            b'A' => {
                numbers(3, &mut lexer)?;
                if lexer.flag().is_none() || lexer.flag().is_none() {
                    return Err(fail("an arc's flags are 0 or 1."));
                }
                numbers(2, &mut lexer)?;
            }
            _ => command = None, // Z
        }
    }
    if !any {
        return Err(fail("it is empty."));
    }
    Ok(())
}

struct Lexer<'a> {
    bytes: &'a [u8],
    index: usize,
}

impl Lexer<'_> {
    fn skip_separators(&mut self) {
        while self.index < self.bytes.len() && [b' ', b'\t', b'\n', b'\r', b','].contains(&self.bytes[self.index]) {
            self.index += 1;
        }
    }

    fn letter(&mut self) -> Option<u8> {
        let byte = *self.bytes.get(self.index)?;
        if !byte.is_ascii_alphabetic() || byte == b'e' || byte == b'E' {
            return None;
        }
        self.index += 1;
        Some(byte)
    }

    fn flag(&mut self) -> Option<bool> {
        self.skip_separators();
        let byte = *self.bytes.get(self.index).filter(|byte| **byte == b'0' || **byte == b'1')?;
        self.index += 1;
        Some(byte == b'1')
    }

    fn number(&mut self) -> Option<f64> {
        self.skip_separators();
        let begin = self.index;
        let bytes = self.bytes;
        if self.index < bytes.len() && (bytes[self.index] == b'+' || bytes[self.index] == b'-') {
            self.index += 1;
        }
        let (mut digits, mut dot) = (false, false);
        while self.index < bytes.len() {
            let byte = bytes[self.index];
            if byte.is_ascii_digit() {
                digits = true;
            } else if byte == b'.' && !dot {
                dot = true;
            } else {
                break;
            }
            self.index += 1;
        }
        if digits && self.index < bytes.len() && (bytes[self.index] == b'e' || bytes[self.index] == b'E') {
            let mut look = self.index + 1;
            if look < bytes.len() && (bytes[look] == b'+' || bytes[look] == b'-') {
                look += 1;
            }
            if look < bytes.len() && bytes[look].is_ascii_digit() {
                self.index = look;
                while self.index < bytes.len() && bytes[self.index].is_ascii_digit() {
                    self.index += 1;
                }
            }
        }
        let value = if digits { std::str::from_utf8(&bytes[begin..self.index]).ok().and_then(|text| text.parse().ok()) } else { None };
        if value.is_none() {
            self.index = begin;
        }
        value
    }
}
