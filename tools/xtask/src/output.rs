//! Structured output helpers.
//!
//! Subcommands should never hand-format their own diagnostics. They either go
//! through `Reporter` for freeform text or emit serde-serialisable structs
//! through `Reporter::json_line` when machine-readable output is useful.

use std::io::{self, IsTerminal, Write};

use serde::Serialize;

pub struct Reporter {
    verbose: bool,
    use_colour: bool,
}

impl Reporter {
    pub fn new(verbose: bool) -> Self {
        Self {
            verbose,
            use_colour: io::stdout().is_terminal(),
        }
    }

    pub fn verbose(&self) -> bool {
        self.verbose
    }

    pub fn info(&self, msg: &str) {
        println!("{msg}");
    }

    pub fn success(&self, msg: &str) {
        let styled = if self.use_colour {
            format!("\x1b[32m{msg}\x1b[0m")
        } else {
            msg.to_string()
        };
        println!("{styled}");
    }

    pub fn error(&self, msg: &str) {
        let mut stderr = io::stderr().lock();
        let styled = if io::stderr().is_terminal() {
            format!("\x1b[31merror:\x1b[0m {msg}")
        } else {
            format!("error: {msg}")
        };
        let _ = writeln!(stderr, "{styled}");
    }

    pub fn trace_command(&self, line: &str) {
        if !self.verbose {
            return;
        }
        let styled = if self.use_colour {
            format!("\x1b[2m$ {line}\x1b[0m")
        } else {
            format!("$ {line}")
        };
        println!("{styled}");
    }

    #[allow(dead_code)]
    pub fn json_line<T: Serialize>(&self, value: &T) -> anyhow::Result<()> {
        let line = serde_json::to_string(value)?;
        println!("{line}");
        Ok(())
    }
}
