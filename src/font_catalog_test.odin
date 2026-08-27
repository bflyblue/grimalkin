package main

import "core:strings"
import "core:testing"

test_font_catalog :: proc(names: []string, automatic_index := 0) -> Font_Catalog {
	catalog := Font_Catalog{automatic_index = automatic_index}
	for name in names {
		append(&catalog.families, Font_Family{name = strings.clone(name)})
	}
	return catalog
}

@(test)
font_catalog_resolves_saved_names_and_missing_names_to_automatic :: proc(t: ^testing.T) {
	catalog := test_font_catalog([]string{"Consolas", "JetBrains Mono", "Fira Code", "Monospacé Élégant"})
	defer font_catalog_destroy(&catalog)
	index, exact := font_catalog_resolve(&catalog, "jetbrains mono")
	testing.expect(t, exact)
	testing.expect_value(t, index, 1)
	index, exact = font_catalog_resolve(&catalog, "Missing Mono")
	testing.expect(t, !exact)
	testing.expect_value(t, index, 0)
	index, exact = font_catalog_resolve(&catalog, "auto")
	testing.expect(t, exact)
	testing.expect_value(t, index, 0)
	index, exact = font_catalog_resolve(&catalog, "monospacé Élégant")
	testing.expect(t, exact)
	testing.expect_value(t, index, 3)
}

@(test)
font_catalog_saved_preference_repairs_names_but_survives_environment_override :: proc(t: ^testing.T) {
	catalog := test_font_catalog([]string{"Consolas", "JetBrains Mono"})
	defer font_catalog_destroy(&catalog)

	preference, _ := font_family_setting_make("jetbrains mono")
	index, repaired, missing := font_catalog_resolve_saved_preference(&catalog, &preference)
	testing.expect_value(t, index, 1)
	testing.expect(t, repaired)
	testing.expect(t, !missing)
	testing.expect_value(t, font_family_setting_name(&preference), "JetBrains Mono")

	preference, _ = font_family_setting_make("Unavailable Mono")
	index, repaired, missing = font_catalog_resolve_saved_preference(&catalog, &preference)
	testing.expect_value(t, index, 0)
	testing.expect(t, repaired)
	testing.expect(t, missing)
	testing.expect_value(t, font_family_setting_name(&preference), "auto")

	catalog.environment_override = true
	preference, _ = font_family_setting_make("Unavailable Mono")
	_, repaired, missing = font_catalog_resolve_saved_preference(&catalog, &preference)
	testing.expect(t, !repaired)
	testing.expect(t, !missing)
	testing.expect_value(t, font_family_setting_name(&preference), "Unavailable Mono")
}

@(test)
font_catalog_platform_preferences_choose_a_known_family :: proc(t: ^testing.T) {
	names := []string{
		"Courier New",
		"DejaVu Sans Mono",
		"Menlo",
		"Consolas",
		"Cascadia Mono",
	}
	catalog := test_font_catalog(names)
	defer font_catalog_destroy(&catalog)
	index := font_catalog_choose_automatic(&catalog)
	when ODIN_OS == .Windows {
		testing.expect_value(t, catalog.families[index].name, "Cascadia Mono")
	} else when ODIN_OS == .Darwin {
		testing.expect_value(t, catalog.families[index].name, "Menlo")
	} else {
		testing.expect_value(t, catalog.families[index].name, "DejaVu Sans Mono")
	}
}

@(test)
font_catalog_native_discovery_returns_usable_exact_face_records :: proc(t: ^testing.T) {
	catalog, ok := font_catalog_init()
	defer font_catalog_destroy(&catalog)
	testing.expect(t, ok)
	testing.expect(t, len(catalog.families) > 0)
	testing.expect(t, catalog.automatic_index >= 0)
	for family in catalog.families {
		testing.expect(t, family.name != "")
		for face in family.faces {
			testing.expect(t, face.path != "")
		}
	}
	for family, index in catalog.families {
		for previous in catalog.families[:index] {
			testing.expect(t, !font_ascii_equal_fold(family.name, previous.name))
		}
	}
}
