require "spec_helper"

module Scenic
  module Adapters
    describe Postgres, "cascade with cross-schema dependencies", :db, :silence do
      let(:adapter) { Postgres.new }

      before do
        # Create analytics schema
        ar_connection.execute("CREATE SCHEMA IF NOT EXISTS analytics")
      end

      after do
        # Clean up analytics schema
        ar_connection.execute("DROP SCHEMA IF EXISTS analytics CASCADE")
      end

      describe "cross-schema dependency handling" do
        context "when dependent view is in different schema" do
          before do
            # Create base view in public schema
            adapter.create_materialized_view("base_data", "SELECT 'original' AS value, 1 AS id")
            add_index(:base_data, :id, name: "base_data_id_idx")

            # Create dependent views in public schema
            adapter.create_materialized_view("public_dependent", "SELECT value || '_public' AS result FROM base_data")
            add_index(:public_dependent, :result, name: "public_dependent_result_idx")

            # Create dependent view in analytics schema
            ar_connection.execute(<<-SQL)
              CREATE MATERIALIZED VIEW analytics.cross_schema_dependent AS
              SELECT value || '_analytics' AS analysis_result FROM base_data
            SQL
            ar_connection.execute("CREATE INDEX analytics_dependent_idx ON analytics.cross_schema_dependent (analysis_result)")
          end

          it "finds and updates dependencies across schemas" do
            new_definition = "SELECT 'updated' AS value, 1 AS id"

            adapter.update_materialized_view("base_data", new_definition, cascade: true)

            # Verify base view updated
            base_result = ar_connection.execute("SELECT * FROM base_data").first["value"]
            expect(base_result).to eq "updated"

            # Verify public schema dependent updated
            public_result = ar_connection.execute("SELECT * FROM public_dependent").first["result"]
            expect(public_result).to eq "updated_public"

            # Verify analytics schema dependent updated
            analytics_result = ar_connection.execute("SELECT * FROM analytics.cross_schema_dependent").first["analysis_result"]
            expect(analytics_result).to eq "updated_analytics"
          end

          it "preserves indexes on cross-schema dependencies" do
            new_definition = "SELECT 'updated' AS value, 1 AS id"

            adapter.update_materialized_view("base_data", new_definition, cascade: true)

            # Check base indexes
            base_indexes = indexes_for("base_data")
            expect(base_indexes.length).to eq 1
            expect(base_indexes.first.index_name).to eq "base_data_id_idx"

            # Check public dependent indexes
            public_indexes = indexes_for("public_dependent")
            expect(public_indexes.length).to eq 1
            expect(public_indexes.first.index_name).to eq "public_dependent_result_idx"

            # Check analytics schema indexes
            analytics_indexes = ar_connection.execute(<<-SQL)
              SELECT i.relname as index_name
              FROM pg_class t
              INNER JOIN pg_index d ON t.oid = d.indrelid
              INNER JOIN pg_class i ON d.indexrelid = i.oid
              LEFT JOIN pg_namespace n ON n.oid = t.relnamespace
              WHERE t.relname = 'cross_schema_dependent'
                AND n.nspname = 'analytics'
                AND i.relkind = 'i'
                AND d.indisprimary = 'f'
            SQL

            expect(analytics_indexes.count).to eq 1
            expect(analytics_indexes.first["index_name"]).to eq "analytics_dependent_idx"
          end

          it "handles multi-level cross-schema dependencies" do
            # Add another level: analytics view depending on public dependent
            ar_connection.execute(<<-SQL)
              CREATE MATERIALIZED VIEW analytics.second_level AS
              SELECT result || '_level2' AS final_result FROM public_dependent
            SQL

            new_definition = "SELECT 'multilevel' AS value, 1 AS id"

            adapter.update_materialized_view("base_data", new_definition, cascade: true)

            # Verify all levels updated correctly
            second_level_result = ar_connection.execute("SELECT * FROM analytics.second_level").first["final_result"]
            expect(second_level_result).to eq "multilevel_public_level2"
          end

          it "recreates cross-schema views in correct schema" do
            new_definition = "SELECT 'updated' AS value, 1 AS id"

            adapter.update_materialized_view("base_data", new_definition, cascade: true)

            # Verify analytics view exists in analytics schema (not public)
            analytics_exists = ar_connection.execute(<<-SQL).first["exists"]
              SELECT EXISTS (
                SELECT 1 FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname = 'cross_schema_dependent'
                  AND n.nspname = 'analytics'
              ) AS exists
            SQL

            expect(analytics_exists).to be true

            # Verify it does NOT exist in public schema
            public_exists = ar_connection.execute(<<-SQL).first["exists"]
              SELECT EXISTS (
                SELECT 1 FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relname = 'cross_schema_dependent'
                  AND n.nspname = 'public'
              ) AS exists
            SQL

            expect(public_exists).to be false
          end
        end

        context "when base view is in non-public schema" do
          before do
            # Create base view in analytics schema
            ar_connection.execute(<<-SQL)
              CREATE MATERIALIZED VIEW analytics.base_view AS
              SELECT 'data' AS value
            SQL

            # Create dependent in public that references analytics view
            adapter.create_materialized_view("public_uses_analytics", "SELECT value || '_public' AS result FROM analytics.base_view")
          end

          it "updates base view and dependent correctly" do
            new_definition = "SELECT 'newdata' AS value"

            # Update the analytics.base_view
            ar_connection.execute("DROP MATERIALIZED VIEW analytics.base_view CASCADE")
            ar_connection.execute("CREATE MATERIALIZED VIEW analytics.base_view AS #{new_definition}")
            ar_connection.execute("CREATE MATERIALIZED VIEW public_uses_analytics AS SELECT value || '_public' AS result FROM analytics.base_view")

            # Verify
            result = ar_connection.execute("SELECT * FROM public_uses_analytics").first["result"]
            expect(result).to eq "newdata_public"
          end
        end

        context "error handling with cross-schema dependencies" do
          before do
            adapter.create_materialized_view("base", "SELECT 'data' AS value")
            ar_connection.execute(<<-SQL)
              CREATE MATERIALIZED VIEW analytics.dependent AS
              SELECT value FROM base
            SQL
          end

          it "rolls back cross-schema changes on failure" do
            invalid_definition = "SELECT invalid_column AS value"

            expect {
              adapter.update_materialized_view("base", invalid_definition, cascade: true)
            }.to raise_error(Scenic::Adapters::Postgres::CascadeUpdateFailedError)

            # Verify original views still exist in both schemas
            base_result = ar_connection.execute("SELECT * FROM base").first["value"]
            expect(base_result).to eq "data"

            dependent_result = ar_connection.execute("SELECT * FROM analytics.dependent").first["value"]
            expect(dependent_result).to eq "data"
          end
        end

        context "mixed regular and materialized views across schemas" do
          before do
            adapter.create_materialized_view("base", "SELECT 'data' AS value")

            # Regular view in analytics schema
            ar_connection.execute(<<-SQL)
              CREATE VIEW analytics.regular_view AS
              SELECT value || '_regular' AS processed FROM base
            SQL

            # Materialized view in analytics depending on regular view
            ar_connection.execute(<<-SQL)
              CREATE MATERIALIZED VIEW analytics.mat_on_regular AS
              SELECT processed || '_materialized' AS final FROM analytics.regular_view
            SQL
          end

          it "handles mixed types across schemas correctly" do
            new_definition = "SELECT 'updated' AS value"

            adapter.update_materialized_view("base", new_definition, cascade: true)

            # Verify regular view recreated as regular
            view_type = ar_connection.execute(<<-SQL).first["relkind"]
              SELECT c.relkind
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relname = 'regular_view' AND n.nspname = 'analytics'
            SQL
            expect(view_type).to eq "v"  # regular view

            # Verify materialized view recreated as materialized
            mat_view_type = ar_connection.execute(<<-SQL).first["relkind"]
              SELECT c.relkind
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relname = 'mat_on_regular' AND n.nspname = 'analytics'
            SQL
            expect(mat_view_type).to eq "m"  # materialized view

            # Verify data flow
            final_result = ar_connection.execute("SELECT * FROM analytics.mat_on_regular").first["final"]
            expect(final_result).to eq "updated_regular_materialized"
          end
        end
      end
    end
  end
end
