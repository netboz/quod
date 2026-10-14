//! The result-term grammar, not an evaluator or a source-language parser.
use crate::{require, Result};

#[derive(Clone, Debug, PartialEq)]
pub enum Term {
    Atom(String),
    Binary(Vec<u8>),
    Number(String),
    Variable(String),
    Call(String, Vec<Term>),
    List(Vec<Term>, Option<Box<Term>>),
}

impl Term {
    pub fn args(&self, name: &str, count: usize) -> Result<&[Term]> {
        match self {
            Self::Call(n, a) if n == name && a.len() == count => Ok(a),
            _ => Err(format!("expected {name}/{count}")),
        }
    }
    pub fn atom(&self, name: &str) -> bool {
        matches!(self, Self::Atom(n) if n == name)
    }
    pub fn bytes(&self) -> Result<&[u8]> {
        match self {
            Self::Binary(b) => Ok(b),
            _ => Err("expected binary".into()),
        }
    }
    pub fn text(&self) -> Result<&str> {
        let s = std::str::from_utf8(self.bytes()?).map_err(|_| "invalid UTF-8")?;
        require(!s.is_empty(), "empty text")?;
        Ok(s)
    }
    pub fn list(&self) -> Result<&[Term]> {
        match self {
            Self::List(a, None) => Ok(a),
            _ => Err("expected proper list".into()),
        }
    }
    pub fn integer(&self) -> Result<i64> {
        match self {
            Self::Number(n) => n.parse().map_err(|_| "expected bounded integer".into()),
            _ => Err("expected integer".into()),
        }
    }
    pub fn ground(&self) -> bool {
        match self {
            Self::Variable(_) | Self::List(_, Some(_)) => false,
            Self::Call(_, a) | Self::List(a, None) => a.iter().all(Self::ground),
            _ => true,
        }
    }
    pub fn render(&self) -> String {
        match self {
            Self::Atom(a) => quote_atom(a),
            Self::Variable(a) | Self::Number(a) => a.clone(),
            Self::Binary(b) => binary(b),
            Self::Call(n, a) => format!(
                "{}({})",
                quote_atom(n),
                a.iter().map(Self::render).collect::<Vec<_>>().join(",")
            ),
            Self::List(a, tail) => format!(
                "[{}{}]",
                a.iter().map(Self::render).collect::<Vec<_>>().join(","),
                tail.as_ref()
                    .map(|t| format!("|{}", t.render()))
                    .unwrap_or_default()
            ),
        }
    }
}

fn escape(c: char, quote: char) -> String {
    match c {
        '\\' => "\\\\".into(),
        '\n' => "\\n".into(),
        '\r' => "\\r".into(),
        '\t' => "\\t".into(),
        c if c == quote => format!("\\{c}"),
        c if (c as u32) < 32 => format!("\\x{:02x}\\", c as u32),
        c => c.to_string(),
    }
}
pub fn binary(b: &[u8]) -> String {
    format!(
        "<<\"{}\">>",
        b.iter()
            .map(|&b| if b > 126 {
                format!("\\x{b:02x}\\")
            } else {
                escape(b as char, '"')
            })
            .collect::<String>()
    )
}
fn quote_atom(a: &str) -> String {
    if a.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && a.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
    {
        a.into()
    } else {
        format!(
            "'{}'",
            a.chars().map(|c| escape(c, '\'')).collect::<String>()
        )
    }
}
pub fn parse(s: &str) -> Result<Term> {
    let mut p = Parser {
        chars: s.chars().collect(),
        at: 0,
    };
    let term = p.term(0)?;
    p.space();
    require(p.at == p.chars.len(), "trailing term content")?;
    Ok(term)
}
struct Parser {
    chars: Vec<char>,
    at: usize,
}
impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }
    fn take(&mut self) -> Result<char> {
        let c = self.peek().ok_or("term ends early")?;
        self.at += 1;
        Ok(c)
    }
    fn space(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.at += 1;
        }
    }
    fn expect(&mut self, c: char) -> Result<()> {
        require(self.take()? == c, "unexpected term delimiter")
    }
    fn escaped(&mut self) -> Result<char> {
        match self.take()? {
            c @ ('"' | '\'' | '\\') => Ok(c),
            'n' => Ok('\n'),
            'r' => Ok('\r'),
            't' => Ok('\t'),
            'b' => Ok('\x08'),
            'f' => Ok('\x0c'),
            'v' => Ok('\x0b'),
            'x' => {
                let mut s = String::new();
                while self.peek().is_some_and(|c| c.is_ascii_hexdigit()) {
                    s.push(self.take()?);
                }
                self.expect('\\')?;
                let n = u32::from_str_radix(&s, 16).map_err(|_| "invalid hex escape")?;
                char::from_u32(n).ok_or("invalid escaped character".into())
            }
            _ => Err("unsupported escape".into()),
        }
    }
    fn quoted(&mut self, quote: char) -> Result<String> {
        let mut s = String::new();
        loop {
            match self.take()? {
                c if c == quote => return Ok(s),
                '\\' => s.push(self.escaped()?),
                c => s.push(c),
            }
        }
    }
    fn term(&mut self, depth: usize) -> Result<Term> {
        require(depth <= 64, "term too deeply nested")?;
        self.space();
        let first = self.take()?;
        match first {
            '<' => {
                self.expect('<')?;
                self.expect('"')?;
                let s = self.quoted('"')?;
                self.expect('>')?;
                self.expect('>')?;
                let bytes = s
                    .chars()
                    .map(|c| u8::try_from(c as u32).map_err(|_| "binary byte out of range".into()))
                    .collect::<Result<Vec<_>>>()?;
                Ok(Term::Binary(bytes))
            }
            '[' => {
                self.space();
                let mut items = Vec::new();
                if self.peek() == Some(']') {
                    self.at += 1;
                    return Ok(Term::List(items, None));
                }
                loop {
                    items.push(self.term(depth + 1)?);
                    self.space();
                    match self.take()? {
                        ']' => return Ok(Term::List(items, None)),
                        ',' => (),
                        '|' => {
                            let tail = self.term(depth + 1)?;
                            self.space();
                            self.expect(']')?;
                            return Ok(Term::List(items, Some(Box::new(tail))));
                        }
                        _ => return Err("invalid list delimiter".into()),
                    }
                }
            }
            '\'' => {
                let name = self.quoted('\'')?;
                self.call(name, depth)
            }
            c if c == '-' || c.is_ascii_digit() => {
                let mut n = c.to_string();
                while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                    n.push(self.take()?);
                }
                if self.peek() == Some('.') {
                    n.push(self.take()?);
                    require(
                        self.peek().is_some_and(|c| c.is_ascii_digit()),
                        "invalid decimal",
                    )?;
                    while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                        n.push(self.take()?);
                    }
                }
                if matches!(self.peek(), Some('e' | 'E')) {
                    n.push(self.take()?);
                    if matches!(self.peek(), Some('+' | '-')) {
                        n.push(self.take()?);
                    }
                    require(
                        self.peek().is_some_and(|c| c.is_ascii_digit()),
                        "invalid exponent",
                    )?;
                    while self.peek().is_some_and(|c| c.is_ascii_digit()) {
                        n.push(self.take()?);
                    }
                }
                if n.contains(['.', 'e', 'E']) {
                    require(n.parse::<f64>().is_ok_and(f64::is_finite), "invalid number")?;
                } else {
                    require(n != "-", "invalid integer")?;
                }
                Ok(Term::Number(n))
            }
            c if c.is_ascii_alphabetic() || c == '_' => {
                let mut name = c.to_string();
                while self
                    .peek()
                    .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    name.push(self.take()?);
                }
                if c.is_ascii_uppercase() || c == '_' {
                    Ok(Term::Variable(name))
                } else {
                    self.call(name, depth)
                }
            }
            _ => Err("invalid term".into()),
        }
    }
    fn call(&mut self, name: String, depth: usize) -> Result<Term> {
        if self.peek() != Some('(') {
            return Ok(Term::Atom(name));
        }
        self.at += 1;
        let mut args = Vec::new();
        loop {
            args.push(self.term(depth + 1)?);
            self.space();
            match self.take()? {
                ')' => return Ok(Term::Call(name, args)),
                ',' => (),
                _ => return Err("invalid argument delimiter".into()),
            }
        }
    }
}
