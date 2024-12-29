import 'package:ev_charging_station/providers/user_recommendation_provider.dart';
import 'package:ev_charging_station/screens/savedStations/saved_stations_screen.dart';
import 'package:ev_charging_station/screens/savedStations/saved_stations_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:main_service_api/main_service_api.dart';
import 'package:provider/provider.dart';
import '../providers/charging_station_provider.dart';
import '../providers/main_service_provider.dart';
import '../providers/token_provider.dart';
import '../providers/user_provider.dart';
import 'filterNearby/filter_popup_viewmodel.dart';
import '../widgets/recommended_stations_list.dart';
import '../services/location_service.dart';
import '../widgets/station_card_2.dart';
import '../services/google_api_service.dart';
import 'filterNearby/filter_popup.dart';
import 'near_me_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? mapController;
  LatLng? _center;
  final Set<Marker> _markers = {};
  ChargingStationResponseWithoutIdentifiers? _selectedStation;
  List<ChargingStationResponseWithoutIdentifiers> chargingStationList = [];
  List<ChargingStationResponseWithoutIdentifiers> _recommendedStations = [];
  List<StationInfo> stationInfoList = [];
  List<dynamic> _searchResults = [];
  final ApiService apiService = ApiService();
  final Map<String, Set<MarkerId>> _filterMarkers = {};
  LatLng? _myLocation;
  LatLngBounds? _visibleRegion;

  @override
  void initState() {
    super.initState();
    _getUserLocation().then((_) async {
      final userChargingStationProvider = Provider.of<UserChargingStationProvider>(context, listen: false);
      setState(() {
        chargingStationList = userChargingStationProvider.chargingStations;
      });
      _addMarkers();
      _calculateScoresAndRecommendations();
    });
  }

  Future<void> _getUserLocation() async {
    LatLng? userLocation = await LocationService().getUserLocation();
    if (userLocation != null) {
      setState(() {
        _center = userLocation;
        _myLocation = _center;
      });
    }
  }

  void _onCardTapped(ChargingStationResponseWithoutIdentifiers station) {
    final position = LatLng(station.latitude!, station.longitude!);
    setState(() {
      _selectedStation = station;
      _center = position;
    });
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(position, 15));
    _applyFilters(context);
  }

  Future<void> _searchPlaces(String query) async {
    _searchResults = await apiService.searchPlaces(_center, query);
    setState(() {});
  }

  Future<void> _navigateToPlace(String placeId) async {
    final position = await apiService.navigateToPlace(placeId);
    if (position != null) {
      setState(() {
        _center = position;
        _searchResults.clear();
      });
      mapController?.animateCamera(CameraUpdate.newLatLngZoom(position, 15));
      _calculateScoresAndRecommendations();
    }
  }

  Future<void> _addMarkers() async {
    if (_myLocation != null) {
      String currentLocationIcon = 'assets/images/markers/current_location_marker.png';
      BitmapDescriptor customIcon = await BitmapDescriptor.asset(
        const ImageConfiguration(size: Size(55, 55)),
        currentLocationIcon,
      );
      _markers.add(
        Marker(
          markerId: const MarkerId("my_location"),
          position: _myLocation!,
          infoWindow: const InfoWindow(title: "Current Location"),
          icon: customIcon,
        ),
      );
    }
    for (ChargingStationResponseWithoutIdentifiers station in chargingStationList) {
      if (_isMarkerInVisibleRegion(station)) {
        String customIconPath = 'assets/images/markers/ev_station_marker.png';
        BitmapDescriptor customIcon = await BitmapDescriptor.asset(
          const ImageConfiguration(size: Size(55, 55)),
          customIconPath,
        );
        _markers.add(
          Marker(
            markerId: MarkerId(station.id.toString()),
            position: LatLng(station.latitude!, station.longitude!),
            infoWindow: InfoWindow(
              title: station.name,
              snippet: 'Loading',
            ),
            onTap: () => _onMarkerTapped(station),
            icon: customIcon,
          ),
        );
      }
    }
    setState(() {});
  }

  bool _isMarkerInVisibleRegion(ChargingStationResponseWithoutIdentifiers station) {
    if (_visibleRegion == null) return true;
    return _visibleRegion!.contains(LatLng(station.latitude!, station.longitude!));
  }

  void _onMarkerTapped(ChargingStationResponseWithoutIdentifiers station) async {
    final userChargingStationProvider = Provider.of<UserChargingStationProvider>(context, listen: false);
    userChargingStationProvider.calculateChargerAvailability();
    final chargerAvailabilityList = userChargingStationProvider.chargerAvailabilityOfRecommendedStationList;
    final chargersAvailability = chargerAvailabilityList.firstWhere(
          (list) => list.any(
            (charger) => station.chargers!.any((stCharger) => stCharger.id == charger['chargerId']),
      ),
      orElse: () => [],
    );
    final availability = calculateAcDcAvailability(station, chargersAvailability);
    int acAvailable = availability[0]!;
    int dcAvailable = availability[1]!;
    Marker updatedMarker = _markers.firstWhere((marker) => marker.markerId.value == station.id.toString());
    _markers.remove(updatedMarker);
    _markers.add(
      updatedMarker.copyWith(
        infoWindowParam: InfoWindow(
          title: station.name,
          snippet: 'AC: $acAvailable, DC: $dcAvailable',
        ),
      ),
    );
    setState(() {
      _selectedStation = station;
      _center = LatLng(station.latitude!, station.longitude!);
    });
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(LatLng(station.latitude!, station.longitude!), 15));
    _applyFilters(context);
  }

  void _closeInfoWindow() {
    setState(() {
      _selectedStation = null;
    });
  }

  Future<void> _calculateScoresAndRecommendations() async {
    _recommendedStations = [];
    final userStationRecommendationProvider = Provider.of<UserRecommendationProvider>(context, listen: false);
    if (_center == null) return;
    await userStationRecommendationProvider.generateUserStationRecommendation(_center);
    final List<StationInfo> updatedStationInfoList = userStationRecommendationProvider.userRecommendedStations;
    List<ChargingStationResponseWithoutIdentifiers> updatedRecommendedStations = [];
    for (var stationInfo in updatedStationInfoList) {
      final stationEntityInfo = stationInfo.stationEntity;
      if (stationEntityInfo != null && stationEntityInfo.oneOf.value is StationEntity) {
        final stationEntity = stationEntityInfo.oneOf.value as StationEntity;
        for (var station in chargingStationList) {
          if (station.id.toString() == stationEntity.id.toString()) {
            updatedRecommendedStations.add(station);
          }
        }
      }
    }
    setState(() {
      stationInfoList = updatedStationInfoList;
      _recommendedStations = updatedRecommendedStations;
    });
  }

  void _showFilterPopUp(BuildContext context) {
    final filterViewModel = Provider.of<FilterViewModel>(context, listen: false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => FilterPopup(),
    ).whenComplete(() {
      filterViewModel.resetTempFilters();
      filterViewModel.filterOptions.forEach((filter, isSelected) {
        if (!isSelected) {
          _removeFilterMarkers(filter.toLowerCase().replaceAll(" ", "_"));
        }
      });
    });
  }

  void _applyFilters(BuildContext context) {
    final filterViewModel = Provider.of<FilterViewModel>(context, listen: false);
    filterViewModel.filterOptions.forEach((filter, isSelected) {
      String filterType = filter.toLowerCase().replaceAll(" ", "_");
      if (isSelected) {
        _searchNearBy(filterType);
      }
    });
  }

  void _removeFilterMarkers(String filterType) {
    if (_filterMarkers.containsKey(filterType)) {
      setState(() {
        _markers.removeWhere((marker) => _filterMarkers[filterType]!.contains(marker.markerId));
        _filterMarkers[filterType]?.clear();
      });
    }
  }

  Future<void> _searchNearBy(String type) async {
    if (_center == null) return;
    const int radius = 1000;
    List<dynamic> results = await apiService.searchNearBy(_center!, radius, type);
    _addFilterMarkers(results, type);
  }

  void _addFilterMarkers(List<dynamic> places, String filterType) async {
    Set<Marker> filterMarkers = <Marker>{};
    Map<String, String> filterIcons = {
      'hospital': 'assets/images/markers/hospital_marker.png',
      'school': 'assets/images/markers/school_marker.png',
      'pharmacy': 'assets/images/markers/pharmacy_marker.png',
      'market': 'assets/images/markers/market_marker.png',
      'shopping_mall': 'assets/images/markers/shopping_marker.png',
      'cafe': 'assets/images/markers/cafe_marker.png',
      'park': 'assets/images/markers/park_marker.png',
      'hotel': 'assets/images/markers/hotel_marker.png',
      'gym': 'assets/images/markers/gym_marker.png',
      'restaurant': 'assets/images/markers/restaurant_marker.png',
      'bank': 'assets/images/markers/bank_marker.png'
    };
    String customIconPath = filterIcons[filterType] ?? 'assets/images/markers/ev_station_marker.png';
    BitmapDescriptor customIcon = await BitmapDescriptor.asset(
      const ImageConfiguration(size: Size(55, 55)),
      customIconPath,
    );
    Set<MarkerId> filterMarkerIds = _filterMarkers.putIfAbsent(filterType, () => <MarkerId>{});
    for (var place in places) {
      final marker = Marker(
        markerId: MarkerId(place['place_id']),
        position: LatLng(
          place['geometry']['location']['lat'],
          place['geometry']['location']['lng'],
        ),
        infoWindow: InfoWindow(
          title: place['name'],
          snippet: place['vicinity'],
        ),
        icon: customIcon,
      );
      filterMarkers.add(marker);
      filterMarkerIds.add(marker.markerId);
    }
    setState(() {
      _markers.addAll(filterMarkers);
    });
  }

  void _navigateToSavedStationsScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => SavedStationsScreen()),
    );
  }

  void _navigateToNearMeScreen() {
    if (_center != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => NearMeScreen(
            chargingStations: chargingStationList,
            userLocation: _center!,
            onStationTapped: _updateCameraPosition,
          ),
        ),
      );
    }
  }

  void _updateCameraPosition(LatLng position) {
    setState(() {
      if (_center != null) {
        _center = position;
      }
    });
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(position, 15));
  }

  @override
  Widget build(BuildContext context) {
    if (_center == null) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    return ChangeNotifierProvider(
      create: (_) => SavedStationsViewModel(
        mainServiceProvider: Provider.of<MainServiceProvider>(context, listen: false),
        tokenProvider: Provider.of<TokenProvider>(context, listen: false),
        userProvider: Provider.of<UserProvider>(context, listen: false),
      ),
      child: Scaffold(
        body: Stack(
          children: [
            _center == null
                ? const Center(child: CircularProgressIndicator())
                : GoogleMap(
              onMapCreated: (controller) {
                mapController = controller;
                mapController!.animateCamera(CameraUpdate.newLatLngZoom(_center!, 15));
              },
              initialCameraPosition: CameraPosition(
                target: _center!,
                zoom: 15,
              ),
              markers: _markers,
              onTap: (_) => _closeInfoWindow(),
              onCameraMove: (position) {
                mapController?.getVisibleRegion().then((bounds) {
                  setState(() {
                    _visibleRegion = bounds;
                  });
                });
              },
              onCameraIdle: () {
                _addMarkers();
              },
            ),
            Positioned(
              top: 30.0,
              left: 15.0,
              right: 15.0,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(25.0),
                        boxShadow: const [
                          BoxShadow(
                            color: Colors.black26,
                            blurRadius: 10.0,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search location',
                          prefixIcon: Icon(Icons.search),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 15.0, horizontal: 20.0),
                        ),
                        onChanged: _searchPlaces,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () {
                      _showFilterPopUp(context);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.4),
                            blurRadius: 10.0,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      child: const CircleAvatar(
                        radius: 25,
                        backgroundColor: Colors.white,
                        child: Icon(
                          Icons.filter_list_sharp,
                          color: Colors.blue,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            buildCircleAvatarButton(
              icon: Icons.place,
              iconColor: Colors.blue,
              onTap: () {
                setState(() {
                  _center = _myLocation;
                });
                mapController?.animateCamera(CameraUpdate.newLatLngZoom(_myLocation!, 15));
                _calculateScoresAndRecommendations();
              },
              topPosition: 150.0,
            ),
            buildCircleAvatarButton(
              icon: Icons.favorite,
              iconColor: Colors.red,
              onTap: _navigateToSavedStationsScreen,
              topPosition: 210.0,
            ),
            buildCircleAvatarButton(
              icon: Icons.near_me,
              iconColor: Colors.blue,
              onTap: _navigateToNearMeScreen,
              topPosition: 270.0,
            ),
            if (_searchResults.isNotEmpty)
              Positioned(
                top: 80.0,
                left: 15.0,
                right: 15.0,
                child: Container(
                  color: Colors.white,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    itemBuilder: (context, index) {
                      final suggestion = _searchResults[index];
                      return ListTile(
                        title: Text(suggestion['description']),
                        onTap: () => _navigateToPlace(suggestion['place_id']),
                      );
                    },
                  ),
                ),
              ),
            if (_selectedStation != null && _selectedStation!.latitude != null && _selectedStation!.longitude != null)
              Positioned(
                bottom: 10.0,
                left: 0,
                right: 0,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: StationCard(
                    station: _selectedStation!,
                    onTap: _onCardTapped,
                    userLatitude: _selectedStation!.latitude ?? 0.0,
                    userLongitude: _selectedStation!.longitude ?? 0.0,
                    onFavoriteToggle: (isFavorite) async {
                      if (isFavorite) {
                        final savedStationsViewModel = Provider.of<SavedStationsViewModel>(context, listen: false);
                        savedStationsViewModel.savedStations ??= [];
                        savedStationsViewModel.savedStations!.add(_selectedStation!);
                        await savedStationsViewModel.addSavedAreas(_selectedStation!.id!);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Station added to favorites!')),
                        );
                      }
                    },
                  ),
                ),
              ),
            if (_selectedStation == null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: RecommendedStationsList(
                  recommendedStations: _recommendedStations,
                  onCardTapped: _onCardTapped,
                  userLatitude: _center!.latitude,
                  userLongitude: _center!.longitude,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Widget buildCircleAvatarButton({
  required IconData icon,
  required Color iconColor,
  required VoidCallback onTap,
  required double topPosition,
}) {
  return Positioned(
    top: topPosition,
    right: 10.0,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 10.0,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: CircleAvatar(
          radius: 25,
          backgroundColor: Colors.white,
          child: Icon(
            icon,
            color: iconColor,
            size: 20,
          ),
        ),
      ),
    ),
  );
}
