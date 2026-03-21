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
#[proc_macro_derive(NixOptions, attributes(nixcfg, serde))]
pub fn derive_nix_options(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    match &input.data {
        Data::Struct(data) => derive_struct(&input, data),
        Data::Enum(data) => derive_enum(&input, data),
        Data::Union(_) => panic!("NixOptions cannot be derived for unions"),
    }
}

/// Preferred alias for `NixOptions`.
#[proc_macro_derive(NixCfg, attributes(nixcfg, serde))]
pub fn derive_nix_cfg(input: TokenStream) -> TokenStream {
    derive_nix_options(input)
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
            if attrs.skip || has_serde_skip(&field.attrs) {
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
    let rename_all = get_serde_rename_all(&input.attrs);
    let tag_field = get_serde_tag(&input.attrs);

    // check if this is a tagged enum (variants with fields + #[serde(tag = "...")])
    let has_data_variants = data.variants.iter().any(|v| !v.fields.is_empty());

    if has_data_variants {
        if let Some(tag) = tag_field {
            return derive_tagged_enum(input, data, &tag, rename_all.as_deref());
        }
        panic!("NixOptions enums with data variants require #[serde(tag = \"...\")]");
    }

    // unit-variant enum → Enum type
    let variants: Vec<_> = data
        .variants
        .iter()
        .map(|v| {
            let attrs = parse_field_attrs(&v.attrs);
            let variant_name = attrs.rename.unwrap_or_else(|| {
                apply_rename_convention(&v.ident.to_string(), rename_all.as_deref())
            });
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

/// tagged enum → submodule with discriminator enum + per-variant optional submodules
fn derive_tagged_enum(
    input: &DeriveInput,
    data: &syn::DataEnum,
    tag: &str,
    rename_all: Option<&str>,
) -> TokenStream {
    let name = &input.ident;
    let doc = extract_doc(&input.attrs);

    // collect variant names (for the discriminator enum)
    let variant_names: Vec<String> = data
        .variants
        .iter()
        .map(|v| apply_rename_convention(&v.ident.to_string(), rename_all))
        .collect();

    let variant_name_strs: Vec<_> = variant_names
        .iter()
        .map(|s| quote! { #s.to_string() })
        .collect();

    // build per-variant submodule options
    let variant_entries: Vec<_> = data
        .variants
        .iter()
        .zip(variant_names.iter())
        .filter_map(|(v, vname)| {
            let fields = match &v.fields {
                Fields::Named(f) => &f.named,
                Fields::Unit => return None,
                _ => panic!("tagged enum variants must have named fields or be unit"),
            };

            let field_entries: Vec<_> = fields
                .iter()
                .filter_map(|field| {
                    let attrs = parse_field_attrs(&field.attrs);
                    if attrs.skip || has_serde_skip(&field.attrs) {
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
                        (#schema_name.to_string(), ::nixcfg::OptionDef {
                            type_: #type_expr,
                            description: #desc_expr,
                            default: #default_expr,
                            example: #example_expr,
                            secret: #secret,
                        })
                    })
                })
                .collect();

            if field_entries.is_empty() {
                return None;
            }

            let vname_clone = vname.clone();
            Some(quote! {
                (#vname_clone.to_string(), ::nixcfg::OptionDef {
                    type_: ::nixcfg::SchemaType::Optional(::std::boxed::Box::new(
                        ::nixcfg::SchemaType::Submodule(::std::vec![#(#field_entries),*])
                    )),
                    description: ::std::option::Option::Some(
                        ::std::format!("{} variant configuration", #vname_clone)
                    ),
                    default: ::std::option::Option::None,
                    example: ::std::option::Option::None,
                    secret: false,
                })
            })
        })
        .collect();

    let tag_str = tag.to_string();

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
                let mut opts = ::std::vec![
                    // discriminator field
                    (#tag_str.to_string(), ::nixcfg::OptionDef {
                        type_: ::nixcfg::SchemaType::Enum(::std::vec![#(#variant_name_strs),*]),
                        description: ::std::option::Option::Some(
                            ::std::format!("{} variant selector", stringify!(#name))
                        ),
                        default: ::std::option::Option::None,
                        example: ::std::option::Option::None,
                        secret: false,
                    }),
                ];
                // per-variant optional submodules
                opts.extend(::std::vec![#(#variant_entries),*]);
                opts
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

fn has_serde_skip(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        if !attr.path().is_ident("serde") {
            return false;
        }
        let mut found = false;
        let _ = attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("skip") || meta.path.is_ident("skip_deserializing") {
                found = true;
            }
            Ok(())
        });
        found
    })
}

fn get_serde_rename_all(attrs: &[syn::Attribute]) -> Option<String> {
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let mut val = None;
        let _ = attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("rename_all") {
                let v = meta.value()?;
                let s: syn::LitStr = v.parse()?;
                val = Some(s.value());
            }
            Ok(())
        });
        if val.is_some() {
            return val;
        }
    }
    None
}

fn get_serde_tag(attrs: &[syn::Attribute]) -> Option<String> {
    for attr in attrs {
        if !attr.path().is_ident("serde") {
            continue;
        }
        let mut val = None;
        let _ = attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("tag") {
                let v = meta.value()?;
                let s: syn::LitStr = v.parse()?;
                val = Some(s.value());
            }
            Ok(())
        });
        if val.is_some() {
            return val;
        }
    }
    None
}

/// apply a serde rename convention to a PascalCase variant name
fn apply_rename_convention(pascal: &str, convention: Option<&str>) -> String {
    match convention {
        Some("lowercase") => pascal.to_lowercase(),
        Some("snake_case") => pascal_to_snake(pascal),
        Some("SCREAMING_SNAKE_CASE") => pascal_to_snake(pascal).to_uppercase(),
        Some("camelCase") => {
            let snake = pascal_to_snake(pascal);
            // first part stays lowercase, rest capitalised
            let parts: Vec<&str> = snake.split('_').collect();
            let mut result = parts[0].to_string();
            for p in &parts[1..] {
                let mut chars = p.chars();
                if let Some(c) = chars.next() {
                    result.extend(c.to_uppercase());
                    result.extend(chars);
                }
            }
            result
        }
        Some("kebab-case") => pascal_to_snake(pascal).replace('_', "-"),
        Some(other) => panic!("unsupported serde rename_all convention: {other}"),
        // default: snake_case (matching the schema convention)
        None => pascal_to_snake(pascal),
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
