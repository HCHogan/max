//! The names of an enum's variants, as they are stored and written:
//! given once, for both directions. A name written in one function and
//! read in another, in another file, is two lists to keep alike.

/// A name that isn't one of a type's.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
#[error("unknown {what}: {name:?}")]
pub struct Unknown {
    /// What was to be named, such as `role`.
    pub what: &'static str,
    /// What was given for one.
    pub name: String,
}

/// Gives a `Copy` enum its variants' names: `ALL`, `as_str`, `FromStr`,
/// whose error is [`Unknown`] of `$what`, and `Display`.
#[macro_export]
macro_rules! names {
    ($type:ty, $what:literal, { $($variant:ident => $name:literal),+ $(,)? }) => {
        impl $type {
            /// Every one, in the order they are declared.
            pub const ALL: [Self; $crate::names!(@count $($variant)+)] = [$(Self::$variant),+];

            /// Its name, as it is stored and written.
            #[must_use]
            pub const fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $name,)+
                }
            }
        }

        impl ::core::str::FromStr for $type {
            type Err = $crate::names::Unknown;

            fn from_str(name: &str) -> ::core::result::Result<Self, Self::Err> {
                match name {
                    $($name => Ok(Self::$variant),)+
                    _ => Err($crate::names::Unknown {
                        what: $what,
                        name: name.to_owned(),
                    }),
                }
            }
        }

        impl ::core::fmt::Display for $type {
            fn fmt(&self, f: &mut ::core::fmt::Formatter<'_>) -> ::core::fmt::Result {
                f.pad(self.as_str())
            }
        }
    };
    (@count $($variant:ident)+) => {
        <[()]>::len(&[$($crate::names!(@unit $variant)),+])
    };
    (@unit $variant:ident) => {
        ()
    };
}

#[cfg(test)]
mod tests {
    use serde::Serialize;

    use crate::message::{MediaKind, Platform, Role};

    /// serde writes these into the stored JSON by the names the columns
    /// have them by.
    #[test]
    fn serde_and_the_columns_name_them_alike() {
        fn alike<T>(all: &[T], as_str: fn(T) -> &'static str)
        where
            T: Copy + PartialEq + std::fmt::Debug + Serialize + std::str::FromStr,
        {
            for &one in all {
                assert_eq!(serde_json::to_value(one).unwrap(), as_str(one));
                assert_eq!(as_str(one).parse().ok(), Some(one));
            }
        }
        alike(&Role::ALL, Role::as_str);
        alike(&Platform::ALL, Platform::as_str);
        alike(&MediaKind::ALL, MediaKind::as_str);
        assert_eq!(
            "boss".parse::<Role>().unwrap_err().to_string(),
            r#"unknown role: "boss""#
        );
    }
}
