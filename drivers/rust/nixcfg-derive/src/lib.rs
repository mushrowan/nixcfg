use proc_macro::TokenStream;
use quote::quote;
use syn::{Data, DeriveInput, Fields, Lit, Meta, parse_macro_input};

/// derive `NixOptions` on a struct to generate schema option definitions,
/// or on a unit-variant enum to generate an `Enum` schema type
///
/// ## struct attributes
///
/// doc comments on the struct become the schema description
///
/// ## field attributes
///
/// - `#[nixcfg(secret)]` — mark as a secret (nix side becomes `*File` path)
/// - `#[nixcfg(port)]` — override type to `Port` (for u16 fields)
/// - `#[nixcfg(default = <lit>)]` — set the default value
/// - `#[nixcfg(example = <lit>)]` — set an example value
/// - `#[nixcfg(rename = "name")]` — override the schema field name
/// - `#[nixcfg(skip)]` — exclude from the schema
///
/// ## enum attributes
///
/// - `#[nixcfg(rename = "name")]` on variants to override the variant name
#[proc_macro_derive(NixOptions, attributes(nixcfg))]
pub fn derive_nix_options(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match &input.data {
        Data::Struct(data) => derive_struct(&input, data),
        Data::Enum(data) => derive_enum(&input, data),
        Data::Union(_) => panic!("NixOptions cannot be derived for unions"),
    }
}

fn derive_struct(input: &DeriveInput, data: &syn::DataStruct) -> TokenStream {
    let name = &input.ident;
    let doc = extract_doc(&input.attrs);

    let fields = match &data.fields {
        Fields::Named(f) => &f.named,
        _ => panic!("NixOptions only supports structs with named fields"),
    };

    let option_entries: Vec<_> = fields
        .iter()
        .filter_map(|field| {
            let attrs = parse_field_attrs(&field.attrs);
            if attrs.skip {
                return None;
            }

            let field_ident = field.ident.as_ref().unwrap();
            let field_type = &field.ty;
            let schema_name = attrs.rename.unwrap_or_else(|| field_ident.to_string());
            let doc = extract_doc(&field.attrs);

            let type_expr = if attrs.port {
                quote! { ::nixcfg::SchemaType::Port }
            } else {
                quote! { <#field_type as ::nixcfg::NixType>::schema_type() }
            };

            let desc_expr = match doc {
                Some(d) => quote! { ::std::option::Option::Some(#d.to_string()) },
                None => quote! { ::std::option::Option::None },
            };

            let default_expr = match attrs.default {
                Some(ref lit) => {
                    let json = lit_to_json_tokens(lit);
                    quote! { ::std::option::Option::Some(#json) }
                }
                None => quote! { ::std::option::Option::None },
            };

            let example_expr = match attrs.example {
                Some(ref lit) => {
                    let json = lit_to_json_tokens(lit);
                    quote! { ::std::option::Option::Some(#json) }
                }
                None => quote! { ::std::option::Option::None },
            };

            let secret = attrs.secret;

            Some(quote! {
                (
                    #schema_name.to_string(),
                    ::nixcfg::OptionDef {
                        type_: #type_expr,
                        description: #desc_expr,
                        default: #default_expr,
                        example: #example_expr,
                        secret: #secret,
                    },
                ),
            })
        })
        .collect();

    let desc_impl = match doc {
        Some(d) => quote! {
            fn description() -> ::std::option::Option<&'static str> {
                ::std::option::Option::Some(#d)
            }
        },
        None => quote! {},
    };

    let expanded = quote! {
        impl ::nixcfg::NixOptions for #name {
            fn nix_options() -> ::std::vec::Vec<(::std::string::String, ::nixcfg::OptionDef)> {
                ::std::vec![#(#option_entries)*]
            }

            #desc_impl
        }

        impl ::nixcfg::NixType for #name {
            fn schema_type() -> ::nixcfg::SchemaType {
                ::nixcfg::SchemaType::Submodule(
                    <Self as ::nixcfg::NixOptions>::nix_options()
                )
            }
        }
    };

    expanded.into()
}

fn derive_enum(input: &DeriveInput, data: &syn::DataEnum) -> TokenStream {
    let name = &input.ident;

    let variants: Vec<_> = data
        .variants
        .iter()
        .map(|v| {
            if !v.fields.is_empty() {
                panic!(
                    "NixOptions enums must have unit variants only, but `{}` has fields",
                    v.ident
                );
            }
            let attrs = parse_field_attrs(&v.attrs);
            let variant_name = attrs
                .rename
                .unwrap_or_else(|| pascal_to_snake(&v.ident.to_string()));
            quote! { #variant_name.to_string() }
        })
        .collect();

    let expanded = quote! {
        impl ::nixcfg::NixType for #name {
            fn schema_type() -> ::nixcfg::SchemaType {
                ::nixcfg::SchemaType::Enum(::std::vec![#(#variants),*])
            }
        }
    };

    expanded.into()
}

// ---------- attribute parsing ----------

struct FieldAttrs {
    secret: bool,
    port: bool,
    skip: bool,
    default: Option<Lit>,
    example: Option<Lit>,
    rename: Option<String>,
}

fn parse_field_attrs(attrs: &[syn::Attribute]) -> FieldAttrs {
    let mut result = FieldAttrs {
        secret: false,
        port: false,
        skip: false,
        default: None,
        example: None,
        rename: None,
    };

    for attr in attrs {
        if !attr.path().is_ident("nixcfg") {
            continue;
        }
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("secret") {
                result.secret = true;
            } else if meta.path.is_ident("port") {
                result.port = true;
            } else if meta.path.is_ident("skip") {
                result.skip = true;
            } else if meta.path.is_ident("default") {
                let value = meta.value()?;
                result.default = Some(value.parse::<Lit>()?);
            } else if meta.path.is_ident("example") {
                let value = meta.value()?;
                result.example = Some(value.parse::<Lit>()?);
            } else if meta.path.is_ident("rename") {
                let value = meta.value()?;
                let lit: syn::LitStr = value.parse()?;
                result.rename = Some(lit.value());
            } else {
                return Err(meta.error("unknown nixcfg attribute"));
            }
            Ok(())
        })
        .expect("failed to parse #[nixcfg(...)] attribute");
    }

    result
}

// ---------- helpers ----------

fn extract_doc(attrs: &[syn::Attribute]) -> Option<String> {
    let docs: Vec<String> = attrs
        .iter()
        .filter_map(|attr| {
            if !attr.path().is_ident("doc") {
                return None;
            }
            if let Meta::NameValue(nv) = &attr.meta
                && let syn::Expr::Lit(expr_lit) = &nv.value
                && let Lit::Str(s) = &expr_lit.lit
            {
                return Some(s.value());
            }
            None
        })
        .collect();

    if docs.is_empty() {
        None
    } else {
        let joined = docs.iter().map(|d| d.trim()).collect::<Vec<_>>().join(" ");
        Some(joined)
    }
}

fn lit_to_json_tokens(lit: &Lit) -> proc_macro2::TokenStream {
    match lit {
        Lit::Str(s) => {
            let val = s.value();
            quote! { ::nixcfg::serde_json::Value::String(#val.to_string()) }
        }
        Lit::Int(i) => {
            let val: i64 = i.base10_parse().expect("invalid integer literal");
            quote! { ::nixcfg::serde_json::Value::Number(
                ::nixcfg::serde_json::Number::from(#val)
            ) }
        }
        Lit::Float(f) => {
            let val: f64 = f.base10_parse().expect("invalid float literal");
            quote! { ::nixcfg::serde_json::json!(#val) }
        }
        Lit::Bool(b) => {
            let val = b.value;
            quote! { ::nixcfg::serde_json::Value::Bool(#val) }
        }
        _ => panic!("unsupported literal type in #[nixcfg(...)] attribute"),
    }
}

fn pascal_to_snake(s: &str) -> String {
    let mut result = std::string::String::new();
    for (i, c) in s.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            result.push('_');
        }
        result.extend(c.to_lowercase());
    }
    result
}
