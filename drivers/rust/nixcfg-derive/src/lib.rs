//! proc macro for nixcfg
//!
//! the `#[nixcfg]` attribute macro rewrites field-level `#[nixcfg(...)]`
//! attributes into `#[schemars(extend(...))]` so you can write:
//!
//! ```ignore
//! #[nixcfg]
//! #[derive(JsonSchema, Serialize)]
//! struct Config {
//!     #[nixcfg(secret)]
//!     api_key: String,
//!
//!     #[nixcfg(port)]
//!     listen_port: u16,
//!
//!     #[nixcfg(path)]
//!     data_dir: std::path::PathBuf,
//!
//!     #[nixcfg(skip)]
//!     runtime_handle: std::sync::Arc<()>,
//!
//!     #[nixcfg(description = "prose explanation for nix option docs")]
//!     #[nixcfg(example = "/var/lib/service")]
//!     data_dir_2: String,
//!
//!     // combinations
//!     #[nixcfg(secret, path)]
//!     pem_path: String,
//! }
//! ```
//!
//! the attribute runs before `#[derive(JsonSchema)]` so schemars sees the
//! rewritten `#[schemars(extend(...))]` attributes and emits the right
//! extension properties in the json schema.
//!
//! supported flags: `secret`, `port`, `path`, `skip`
//!
//! supported key=value: `description`, `example`

use proc_macro::TokenStream;
use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::{
    Attribute, Data, DeriveInput, Expr, Fields, Meta, Token, parse_macro_input, parse_quote,
};

/// attribute macro that rewrites `#[nixcfg(...)]` field attributes into
/// `#[schemars(extend(...))]` for nixcfg extension properties
#[proc_macro_attribute]
pub fn nixcfg(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let mut input = parse_macro_input!(item as DeriveInput);

    match rewrite(&mut input) {
        Ok(()) => quote!(#input).into(),
        Err(e) => e.to_compile_error().into(),
    }
}

fn rewrite(input: &mut DeriveInput) -> syn::Result<()> {
    match &mut input.data {
        Data::Struct(s) => match &mut s.fields {
            Fields::Named(named) => {
                for field in &mut named.named {
                    rewrite_attrs(&mut field.attrs)?;
                }
            }
            Fields::Unnamed(unnamed) => {
                for field in &mut unnamed.unnamed {
                    rewrite_attrs(&mut field.attrs)?;
                }
            }
            Fields::Unit => {}
        },
        Data::Enum(e) => {
            for variant in &mut e.variants {
                rewrite_attrs(&mut variant.attrs)?;
                match &mut variant.fields {
                    Fields::Named(named) => {
                        for field in &mut named.named {
                            rewrite_attrs(&mut field.attrs)?;
                        }
                    }
                    Fields::Unnamed(unnamed) => {
                        for field in &mut unnamed.unnamed {
                            rewrite_attrs(&mut field.attrs)?;
                        }
                    }
                    Fields::Unit => {}
                }
            }
        }
        Data::Union(_) => {
            return Err(syn::Error::new(
                input.span(),
                "#[nixcfg] is not supported on unions",
            ));
        }
    }

    // also rewrite top-level attrs (e.g. container-wide description overrides)
    rewrite_attrs(&mut input.attrs)?;
    Ok(())
}

fn rewrite_attrs(attrs: &mut Vec<Attribute>) -> syn::Result<()> {
    let mut new_attrs = Vec::with_capacity(attrs.len());

    for attr in std::mem::take(attrs) {
        if !attr.path().is_ident("nixcfg") {
            new_attrs.push(attr);
            continue;
        }

        let metas: Punctuated<Meta, Token![,]> =
            attr.parse_args_with(Punctuated::parse_terminated)?;

        let mut extend_args: Vec<TokenStream2> = Vec::new();

        for meta in metas {
            match meta {
                Meta::Path(p) => {
                    let key = p
                        .get_ident()
                        .map(|i| i.to_string())
                        .ok_or_else(|| syn::Error::new(p.span(), "expected single identifier"))?;
                    let ext_key = match key.as_str() {
                        "secret" => "x-nixcfg-secret",
                        "port" => "x-nixcfg-port",
                        "path" => "x-nixcfg-path",
                        "skip" => "x-nixcfg-skip",
                        other => {
                            return Err(syn::Error::new(
                                p.span(),
                                format!(
                                    "unknown nixcfg flag `{other}`, expected one of: secret, port, path, skip"
                                ),
                            ));
                        }
                    };
                    extend_args.push(quote!(#ext_key = true));
                }
                Meta::NameValue(nv) => {
                    let key = nv.path.get_ident().map(|i| i.to_string()).ok_or_else(|| {
                        syn::Error::new(nv.path.span(), "expected single identifier")
                    })?;
                    let ext_key = match key.as_str() {
                        "description" => "x-nixcfg-description",
                        "example" => "x-nixcfg-example",
                        other => {
                            return Err(syn::Error::new(
                                nv.path.span(),
                                format!(
                                    "unknown nixcfg key `{other}`, expected one of: description, example"
                                ),
                            ));
                        }
                    };
                    let value: &Expr = &nv.value;
                    extend_args.push(quote!(#ext_key = #value));
                }
                Meta::List(l) => {
                    return Err(syn::Error::new(
                        l.span(),
                        "nested list form is not supported in #[nixcfg(...)], \
                         use flag form (secret) or key=value (description = \"...\")",
                    ));
                }
            }
        }

        if !extend_args.is_empty() {
            let schemars_attr: Attribute = parse_quote! {
                #[schemars(extend(#(#extend_args),*))]
            };
            new_attrs.push(schemars_attr);
        }
    }

    *attrs = new_attrs;
    Ok(())
}
