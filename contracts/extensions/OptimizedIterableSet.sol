pragma solidity ^0.8.0;

contract OptimizedIterableSet {
    // Using mapping to store whether an element exists
    mapping(uint256 => bool) private set;

    // Maintain an array to store the order of added elements
    uint256[] private values;

    // Additional mapping to store the index of each element in the array
    mapping(uint256 => uint256) private indexOf;

    // Add an element to the set
    function add(uint256 value) public {
        // If the element already exists, return immediately
        if (set[value]) {
            remove(value);
        }

        // Mark the element as existing
        set[value] = true;
        // Add the element to the array
        values.push(value);
        // Store the index of the element in the array
        indexOf[value] = values.length - 1;
    }

    // Remove an element from the set
    function remove(uint256 value) public {
        // If the element does not exist, return immediately
        require(set[value], "Value not in set");

        // Mark the element as non-existing
        set[value] = false;

        // Find the index of the element in the array
        uint256 index = indexOf[value];

        // Move the last element in the array to the position of the element to be removed
        uint256 lastValue = values[values.length - 1];
        values[index] = lastValue;

        // Update the index of the last element
        indexOf[lastValue] = index;

        // Remove the last element from the array
        values.pop();

        // Delete the index mapping for the removed element
        delete indexOf[value];
    }

    // Check if an element exists in the set
    function contains(uint256 value) public view returns (bool) {
        return set[value];
    }

    // Get the number of elements in the set
    function size() public view returns (uint256) {
        return values.length;
    }

    // Get all elements in the set as an array
    function getValues() public view returns (uint256[] memory) {
        return values;
    }

    // Access a specific element in the set by index
    function getValueAt(uint256 index) public view returns (uint256) {
        require(index < values.length, "Index out of bounds");
        return values[index];
    }
}
