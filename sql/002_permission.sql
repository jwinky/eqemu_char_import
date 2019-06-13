USE eqemu_char_import;

GRANT SELECT, UPDATE ON requests TO eqemu_importer@localhost;
GRANT SELECT ON whitelisted_items TO eqemu_importer@localhost;

USE eqemu_db;

GRANT SELECT, UPDATE ON character_data TO eqemu_importer@localhost;
GRANT SELECT, INSERT, DELETE ON character_spells TO eqemu_importer@localhost;
GRANT SELECT, INSERT, DELETE ON inventory TO eqemu_importer@localhost;
GRANT SELECT ON items TO eqemu_importer@localhost;
GRANT SELECT ON spells_new TO eqemu_importer@localhost;
GRANT SELECT ON base_data TO eqemu_importer@localhost;
GRANT SELECT ON level_exp_mods TO eqemu_importer@localhost;
GRANT SELECT, INSERT, UPDATE ON character_currency TO eqemu_importer@localhost;
