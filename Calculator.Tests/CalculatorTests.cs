using Xunit;

namespace DevopsPractices.Tests
{
	public class CalculatorTests
	{
		[Fact]
		public void Add_ReturnsSumOfTwoNumbers()
		{
			Assert.Equal(5, Calculator.Add(2, 3));
		}

		[Fact]
		public void Add_WorksWithNegativeNumbers()
		{
			Assert.Equal(-1, Calculator.Add(2, -3));
		}

		[Theory]
		[InlineData(4, true)]
		[InlineData(7, false)]
		[InlineData(0, true)]
		public void IsEven_ReturnsCorrectResult(int number, bool expected)
		{
			Assert.Equal(expected, Calculator.IsEven(number));
		}
	}
}
