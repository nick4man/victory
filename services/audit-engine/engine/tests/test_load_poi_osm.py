"""Unit-тесты для load_poi_osm.

Проверяем только pure-функции: _infer_poi_type, parse_overpass_response,
build_overpass_query. HTTP и БД не трогаем.
"""
import pytest

from scripts.load_poi_osm import (
    POI_TAGS,
    _infer_poi_type,
    build_overpass_query,
    parse_overpass_response,
)


def test_infer_poi_type_metro_subway_entrance():
    assert _infer_poi_type({"railway": "subway_entrance"}) == "metro"


def test_infer_poi_type_metro_station_subway():
    assert _infer_poi_type({"railway": "station", "station": "subway"}) == "metro"


def test_infer_poi_type_school():
    assert _infer_poi_type({"amenity": "school"}) == "school"


def test_infer_poi_type_hospital_and_clinic():
    assert _infer_poi_type({"amenity": "hospital"}) == "hospital"
    assert _infer_poi_type({"amenity": "clinic"}) == "hospital"


def test_infer_poi_type_kindergarten_university():
    assert _infer_poi_type({"amenity": "kindergarten"}) == "kindergarten"
    assert _infer_poi_type({"amenity": "university"}) == "university"
    assert _infer_poi_type({"amenity": "college"}) == "university"


def test_infer_poi_type_park_and_mall():
    assert _infer_poi_type({"leisure": "park"}) == "park"
    assert _infer_poi_type({"shop": "mall"}) == "mall"
    assert _infer_poi_type({"amenity": "marketplace"}) == "mall"


def test_infer_poi_type_unrelated_returns_none():
    assert _infer_poi_type({"amenity": "restaurant"}) is None
    assert _infer_poi_type({}) is None
    assert _infer_poi_type({"natural": "tree"}) is None


def test_parse_overpass_response_node():
    payload = {
        "elements": [
            {
                "type": "node",
                "id": 42,
                "lat": 54.625,
                "lon": 39.735,
                "tags": {"amenity": "school", "name": "Школа №1"},
            }
        ]
    }
    pois = parse_overpass_response(payload, city_label="Рязань")
    assert len(pois) == 1
    p = pois[0]
    assert p.poi_type == "school"
    assert p.name == "Школа №1"
    assert p.latitude == 54.625
    assert p.longitude == 39.735
    assert p.city == "Рязань"
    assert p.osm_id == 42


def test_parse_overpass_response_way_uses_center():
    payload = {
        "elements": [
            {
                "type": "way",
                "id": 100,
                "center": {"lat": 55.75, "lon": 37.61},
                "tags": {"leisure": "park", "name": "ЦПКиО"},
            }
        ]
    }
    pois = parse_overpass_response(payload, city_label=None)
    assert len(pois) == 1
    assert pois[0].poi_type == "park"
    assert pois[0].latitude == 55.75


def test_parse_overpass_response_skips_unnamed():
    payload = {
        "elements": [
            {"type": "node", "id": 1, "lat": 1, "lon": 2, "tags": {"amenity": "school"}},
            {"type": "node", "id": 2, "lat": 3, "lon": 4, "tags": {"amenity": "school", "name": "X"}},
        ]
    }
    assert len(parse_overpass_response(payload, city_label=None)) == 1


def test_parse_overpass_response_skips_unrelated_tags():
    payload = {
        "elements": [
            {"type": "node", "id": 1, "lat": 1, "lon": 2,
             "tags": {"amenity": "restaurant", "name": "X"}},
        ]
    }
    assert parse_overpass_response(payload, city_label=None) == []


def test_parse_overpass_response_address_extraction():
    payload = {
        "elements": [
            {
                "type": "node",
                "id": 1,
                "lat": 1,
                "lon": 2,
                "tags": {
                    "amenity": "school",
                    "name": "Школа",
                    "addr:street": "ул. Ленина",
                    "addr:housenumber": "5",
                },
            }
        ]
    }
    pois = parse_overpass_response(payload, city_label=None)
    assert pois[0].address == "ул. Ленина, 5"


def test_build_overpass_query_contains_all_elem_types():
    q = build_overpass_query((1.0, 2.0, 3.0, 4.0), ["school"])
    assert "node[" in q
    assert "way[" in q
    assert "relation[" in q
    assert '"amenity"="school"' in q
    assert "1.0,2.0,3.0,4.0" in q
    assert "out:json" in q


def test_build_overpass_query_handles_metro_extra_bracket():
    q = build_overpass_query((1.0, 2.0, 3.0, 4.0), ["metro"])
    assert '[station=subway]' in q
    assert '"railway"="subway_entrance"' in q


def test_poi_tags_covers_all_seven_types():
    assert set(POI_TAGS.keys()) == {
        "metro", "school", "hospital", "park", "mall",
        "kindergarten", "university",
    }
