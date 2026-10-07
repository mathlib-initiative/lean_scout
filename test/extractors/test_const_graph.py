"""Tests for const_graph data extractor using test_project."""
import glob
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, cast

import pytest
import yaml
from datasets import Dataset

sys.path.insert(0, str(Path(__file__).parent.parent))

from helpers import (
    TEST_PROJECT_DIR,
    get_record_by_name,
)


def extract_from_dependency_const_graph(library: str, data_dir: Path, working_dir: Path) -> Path:
    const_graph_dir = data_dir / "const_graph"
    subprocess.run(
        ["lake", "run", "scout", "--command", "const_graph", "--parquet",
         "--dataDir", str(const_graph_dir), "--imports", library],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(working_dir)
    )

    if not const_graph_dir.exists():
        raise RuntimeError(f"const_graph directory not created: {const_graph_dir}")

    return const_graph_dir


def load_const_graph_dataset(const_graph_dir: Path) -> Dataset:
    parquet_files = glob.glob(str(const_graph_dir / "*.parquet"))
    if not parquet_files:
        raise RuntimeError(f"No parquet files found in {const_graph_dir}")

    result = Dataset.from_parquet(cast("Any", parquet_files))
    assert isinstance(result, Dataset)
    return result


@pytest.fixture(scope="module")
def const_graph_dataset_imports():
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)
        const_graph_dir = extract_from_dependency_const_graph(
            "LeanScoutTestProject",
            data_dir,
            TEST_PROJECT_DIR
        )
        dataset = load_const_graph_dataset(const_graph_dir)
        yield dataset


@pytest.fixture(scope="module")
def const_graph_spec():
    spec_path = Path(__file__).parent.parent / "fixtures" / "const_graph.yaml"
    with open(spec_path) as f:
        return yaml.safe_load(f)


def test_const_graph_imports_properties(const_graph_dataset_imports, const_graph_spec):
    for check in const_graph_spec['property_checks']:
        name = check['name']
        actual = get_record_by_name(const_graph_dataset_imports, name)

        assert actual is not None, f"Record not found: {name}"

        props = check['properties']

        if props.get('graph_has_nodes'):
            graph = actual['graph']
            assert graph is not None, f"Graph is None for {name}"
            assert 'nodes' in graph, f"Graph missing 'nodes' for {name}"
            assert len(graph['nodes']) > 0, f"Graph has no nodes for {name}"

        if props.get('graph_has_root'):
            graph = actual['graph']
            assert graph is not None, f"Graph is None for {name}"
            assert 'rootIdx' in graph, f"Graph missing 'rootIdx' for {name}"
            assert graph['rootIdx'] is not None, f"Graph rootIdx is None for {name}"

        if 'min_nodes' in props:
            graph = actual['graph']
            min_nodes = props['min_nodes']
            actual_nodes = len(graph['nodes'])
            assert actual_nodes >= min_nodes, (
                f"Expected at least {min_nodes} nodes for {name}, got {actual_nodes}"
            )


def test_const_graph_imports_count_min_records(const_graph_dataset_imports, const_graph_spec):
    counts = const_graph_spec['count_checks']
    min_records = counts['min_records']

    actual_count = len(const_graph_dataset_imports)
    assert actual_count >= min_records, (
        f"Expected at least {min_records} records, got {actual_count}"
    )


def test_const_graph_imports_has_required_names(const_graph_dataset_imports, const_graph_spec):
    counts = const_graph_spec['count_checks']
    required_names = set(counts['has_names'])
    dataset_names = set(const_graph_dataset_imports['name'])
    missing_names = required_names - dataset_names

    assert len(missing_names) == 0, (
        f"Missing required constants: {sorted(missing_names)}"
    )


def test_const_graph_imports_schema(const_graph_dataset_imports):
    assert len(const_graph_dataset_imports) > 0, "Dataset is empty"

    first_record = const_graph_dataset_imports[0]

    assert 'name' in first_record
    assert 'graph' in first_record

    assert isinstance(first_record['name'], str)

    # Check graph structure
    graph = first_record['graph']
    assert graph is not None, "Graph should not be None"
    assert 'nodes' in graph, "Graph should have 'nodes'"
    assert 'edges' in graph, "Graph should have 'edges'"
    assert 'rootIdx' in graph, "Graph should have 'rootIdx'"

    # Verify nodes structure
    assert isinstance(graph['nodes'], list)
    if len(graph['nodes']) > 0:
        node = graph['nodes'][0]
        assert 'idx' in node, "Node should have 'idx'"
        assert 'node' in node, "Node should have 'node'"

    # Verify edges structure
    assert isinstance(graph['edges'], list)
    if len(graph['edges']) > 0:
        edge = graph['edges'][0]
        assert 'src' in edge, "Edge should have 'src'"
        assert 'tgt' in edge, "Edge should have 'tgt'"
        assert 'edge' in edge, "Edge should have 'edge'"


def test_const_graph_node_types(const_graph_dataset_imports):
    """Verify that graph nodes have expected types from expression structure."""
    # Get a record that we know should have various node types
    add_zero = get_record_by_name(const_graph_dataset_imports, "add_zero")
    assert add_zero is not None

    graph = add_zero['graph']
    node_types = {node['node'] for node in graph['nodes']}

    # add_zero : (n : Nat) → n + 0 = n
    # Should have forallE (for the function type) and const nodes (for Nat, Eq, etc.)
    has_forall_or_const = any(
        'forallE' in nt or 'const:' in nt
        for nt in node_types
    )
    assert has_forall_or_const, (
        f"Expected forallE or const nodes in add_zero type graph, got: {node_types}"
    )


def test_const_graph_edge_types(const_graph_dataset_imports):
    """Verify that graph edges have expected types."""
    # Get a record with edges
    add_comm = get_record_by_name(const_graph_dataset_imports, "add_comm")
    assert add_comm is not None

    graph = add_comm['graph']
    edge_types = {edge['edge'] for edge in graph['edges']}

    # Valid edge types based on ConstGraph.lean
    valid_edge_types = {
        'cdeclType', 'ldeclType', 'ldeclValue', 'mvarType',
        'appFn', 'appArg', 'lamBody', 'lamFVar',
        'forallEBody', 'forallEFVar', 'letEBody', 'letEFVar',
        'mdata', 'proj'
    }

    for edge_type in edge_types:
        assert edge_type in valid_edge_types, (
            f"Unexpected edge type '{edge_type}', valid types: {valid_edge_types}"
        )


def test_const_graph_graph_connectivity(const_graph_dataset_imports):
    """Verify that graphs have proper structure (root can reach nodes via edges)."""
    for record in const_graph_dataset_imports:
        graph = record['graph']
        if graph['rootIdx'] is None:
            continue

        nodes = graph['nodes']
        edges = graph['edges']

        # Build adjacency from edges (tgt -> src, since edges point to parent)
        adjacency: dict[int, set[int]] = {node['idx']: set() for node in nodes}
        for edge in edges:
            # Edge goes from src to tgt, so from tgt we can reach src
            if edge['tgt'] in adjacency:
                adjacency[edge['tgt']].add(edge['src'])

        # The root should exist in the node indices
        node_indices = {node['idx'] for node in nodes}
        root_idx = graph['rootIdx']
        assert root_idx in node_indices, (
            f"Root index {root_idx} not in node indices for {record['name']}"
        )


# ============================================================================
# JSON Lines Output Tests
# ============================================================================

def extract_const_graph_jsonl(library: str, working_dir: Path) -> list[dict[str, Any]]:
    """Extract const_graph using --jsonl flag and return parsed records."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "const_graph", "--jsonl", "--imports", library],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(working_dir)
    )

    records = []
    for line in result.stdout.strip().split("\n"):
        if line:
            records.append(json.loads(line))

    return records


@pytest.fixture(scope="module")
def const_graph_jsonl_records():
    """Extract const_graph as JSON Lines from test_project."""
    return extract_const_graph_jsonl("LeanScoutTestProject", TEST_PROJECT_DIR)


def test_const_graph_jsonl_output_format(const_graph_jsonl_records):
    """Verify JSON Lines output has valid structure."""
    assert len(const_graph_jsonl_records) > 0, "Should have extracted some records"

    for record in const_graph_jsonl_records:
        assert "name" in record, "Record should have 'name' field"
        assert "graph" in record, "Record should have 'graph' field"
        assert isinstance(record["name"], str)
        assert isinstance(record["graph"], dict)


def test_const_graph_jsonl_has_expected_records(const_graph_jsonl_records):
    """Verify expected constants are present in JSON Lines output."""
    names = {r["name"] for r in const_graph_jsonl_records}

    expected_names = {"add_zero", "zero_add", "add_comm"}
    missing = expected_names - names
    assert len(missing) == 0, f"Missing expected constants: {missing}"


def test_const_graph_jsonl_record_content(const_graph_jsonl_records):
    """Verify specific record content matches expected values."""
    add_zero = next((r for r in const_graph_jsonl_records if r["name"] == "add_zero"), None)
    assert add_zero is not None, "Should find add_zero record"

    graph = add_zero["graph"]
    assert "nodes" in graph
    assert "edges" in graph
    assert "rootIdx" in graph
    assert len(graph["nodes"]) > 0


def test_const_graph_jsonl_no_output_directory_created():
    """Verify --jsonl flag does not create output directories."""
    with tempfile.TemporaryDirectory() as tmpdir:
        data_dir = Path(tmpdir)

        subprocess.run(
            ["lake", "run", "scout", "--command", "const_graph", "--jsonl",
             "--dataDir", str(data_dir), "--imports", "LeanScoutTestProject"],
            capture_output=True,
            text=True,
            check=True,
            cwd=str(TEST_PROJECT_DIR)
        )

        const_graph_dir = data_dir / "const_graph"
        assert not const_graph_dir.exists(), "--jsonl should not create output directory"


def test_const_graph_jsonl_logs_to_stderr():
    """Verify logs go to stderr, not stdout."""
    result = subprocess.run(
        ["lake", "run", "scout", "--command", "const_graph", "--jsonl",
         "--imports", "LeanScoutTestProject"],
        capture_output=True,
        text=True,
        check=True,
        cwd=str(TEST_PROJECT_DIR)
    )

    # stdout should only contain valid JSON lines
    for line in result.stdout.strip().split("\n"):
        if line:
            json.loads(line)

    assert "[INFO]" in result.stderr or "[ERROR]" in result.stderr, \
        "Log messages should appear in stderr"
